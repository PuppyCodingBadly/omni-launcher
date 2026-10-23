#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* theme_channel;
  FlMethodChannel* window_channel;
  FlMethodChannel* events_channel;
  // Owned by GtkApplication, not by us: the pointer only says whether the
  // window exists (nulled by its destroy signal).
  GtkWindow* window;
  GtkStatusIcon* tray_icon;
  GtkWidget* tray_menu;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Bring an existing window back instead of making a second one. A second
// launch of the app reaches this through GApplication's single-instance
// activation.
static void present_window(MyApplication* self) {
  if (self->window == nullptr) return;
  GtkWidget* widget = GTK_WIDGET(self->window);
  // Undo hide_window: a hidden window is still mapped, at zero opacity and
  // with input turned off.
  gtk_widget_set_opacity(widget, 1.0);
  GdkWindow* shown_gdk = gtk_widget_get_window(widget);
  if (shown_gdk != nullptr) {
    gdk_window_input_shape_combine_region(shown_gdk, nullptr, 0, 0);
  }
  gtk_window_set_accept_focus(self->window, TRUE);
  gtk_window_set_skip_taskbar_hint(self->window, FALSE);
  gtk_window_set_keep_below(self->window, FALSE);
  gtk_window_deiconify(self->window);
  gtk_window_present(self->window);
}

// Iconifying the window pauses the Flutter/Dart event loop, which stops the
// session watcher from noticing that a launched game exited, so playtime
// would stall and the window would never come back by itself. Hiding it
// instead keeps it mapped and the engine running: no pixels (opacity 0), no
// input and no taskbar entry, which looks the same to the user.
static void hide_window(MyApplication* self) {
  if (self->window == nullptr) return;
  GtkWidget* widget = GTK_WIDGET(self->window);
  gtk_window_set_accept_focus(self->window, FALSE);
  gtk_window_set_skip_taskbar_hint(self->window, TRUE);
  gtk_window_set_keep_below(self->window, TRUE);
  GdkWindow* gdk_window = gtk_widget_get_window(widget);
  if (gdk_window != nullptr) {
    // An empty input region makes clicks pass through to the game. GTK3 has
    // no widget-level can-target; the GDK shape is the equivalent.
    cairo_region_t* empty = cairo_region_create();
    gdk_window_input_shape_combine_region(gdk_window, empty, 0, 0);
    cairo_region_destroy(empty);
    gdk_window_lower(gdk_window);
  }
  gtk_widget_set_opacity(widget, 0.0);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static void window_destroy_cb(GtkWidget* widget, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->window = nullptr;
}

// Dart hears about a focus so it can rescan for games installed while the
// launcher was behind another window.
static gboolean window_focus_cb(GtkWidget* widget,
                                GdkEventFocus* event,
                                gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->events_channel != nullptr) {
    fl_method_channel_invoke_method(self->events_channel, "focus", nullptr,
                                    nullptr, nullptr, nullptr);
  }
  return FALSE;
}

// Pushes the palette choice from Dart to GTK. The header bar and the colour
// behind the first frame are drawn by GTK, not by Flutter, so they would
// otherwise keep the system theme while the window is dark.
static void theme_method_call_cb(FlMethodChannel* channel,
                                 FlMethodCall* method_call,
                                 gpointer user_data) {
  FlView* view = FL_VIEW(user_data);
  if (g_strcmp0(fl_method_call_get_name(method_call), "setDark") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    if (fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
      gboolean dark = fl_value_get_bool(args);
      g_object_set(gtk_settings_get_default(),
                   "gtk-application-prefer-dark-theme", dark, nullptr);
      GdkRGBA background_color;
      gdk_rgba_parse(&background_color, dark ? "#0E0E13" : "#F7F7FA");
      fl_view_set_background_color(view, &background_color);
      fl_method_call_respond_success(method_call, nullptr, nullptr);
      return;
    }
  }
  fl_method_call_respond_not_implemented(method_call, nullptr);
}

// The channel's user_data (view or window) is released with the channel.
static void channel_user_data_destroy(gpointer data) {
  g_object_unref(data);
}

// Dart sends sizes as doubles; GTK wants ints.
static gint fl_value_as_int(FlValue* value) {
  return fl_value_get_type(value) == FL_VALUE_TYPE_INT
             ? (gint)fl_value_get_int(value)
             : (gint)fl_value_get_float(value);
}

static gboolean tray_activate_cb(GtkStatusIcon* icon, gpointer user_data) {
  present_window(MY_APPLICATION(user_data));
  return TRUE;
}

static void tray_show_cb(GtkMenuItem* item, gpointer user_data) {
  present_window(MY_APPLICATION(user_data));
}

static void tray_quit_cb(GtkMenuItem* item, gpointer user_data) {
  g_application_quit(G_APPLICATION(user_data));
}

static void tray_popup_cb(GtkStatusIcon* icon,
                          guint button,
                          guint activate_time,
                          gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->tray_menu == nullptr) return;
  gtk_menu_popup_at_pointer(GTK_MENU(self->tray_menu), nullptr);
}

// The tray is best effort: GtkStatusIcon is a GTK3 icon that desktop shells
// with a tray host show; GNOME on Wayland has none, and turning it on there
// simply draws nothing. The window still works without it.
//
// GTK3 deprecates GtkStatusIcon in favour of app indicators, which would mean
// another runtime dependency; this build keeps the icon that needs nothing.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
static void set_tray_icon(MyApplication* self, gboolean enabled) {
  if (enabled) {
    if (self->tray_icon != nullptr) return;
    const gchar* icon_name = "io.github.PuppyCodingBadly.OmniLauncher";
    if (!gtk_icon_theme_has_icon(gtk_icon_theme_get_default(), icon_name)) {
      icon_name = "applications-games";
    }
    self->tray_icon = gtk_status_icon_new_from_icon_name(icon_name);
    gtk_status_icon_set_tooltip_text(self->tray_icon, "Omni Launcher");
    GtkWidget* menu = gtk_menu_new();
    GtkWidget* show = gtk_menu_item_new_with_label("Show Omni Launcher");
    GtkWidget* quit = gtk_menu_item_new_with_label("Quit");
    g_signal_connect(show, "activate", G_CALLBACK(tray_show_cb), self);
    g_signal_connect(quit, "activate", G_CALLBACK(tray_quit_cb), self);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), show);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), quit);
    gtk_widget_show_all(menu);
    self->tray_menu = menu;
    g_signal_connect(self->tray_icon, "activate",
                     G_CALLBACK(tray_activate_cb), self);
    g_signal_connect(self->tray_icon, "popup-menu",
                     G_CALLBACK(tray_popup_cb), self);
    gtk_status_icon_set_visible(self->tray_icon, TRUE);
    return;
  }
  if (self->tray_icon != nullptr) {
    gtk_status_icon_set_visible(self->tray_icon, FALSE);
    g_object_unref(self->tray_icon);
    self->tray_icon = nullptr;
  }
  if (self->tray_menu != nullptr) {
    gtk_widget_destroy(self->tray_menu);
    self->tray_menu = nullptr;
  }
}
#pragma GCC diagnostic pop

// Window channel: size restore, hiding and the tray toggle. Dart owns the
// decisions; the runner only touches GTK.
static void window_method_call_cb(FlMethodChannel* channel,
                                  FlMethodCall* method_call,
                                  gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  GtkWindow* window = self->window;
  const gchar* name = fl_method_call_get_name(method_call);
  if (g_strcmp0(name, "minimize") == 0) {
    hide_window(self);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }
  if (g_strcmp0(name, "show") == 0) {
    present_window(self);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }
  if (g_strcmp0(name, "setTrayIcon") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    if (fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
      set_tray_icon(self, fl_value_get_bool(args));
      fl_method_call_respond_success(method_call, nullptr, nullptr);
      return;
    }
  }
  if (window == nullptr) {
    fl_method_call_respond_not_implemented(method_call, nullptr);
    return;
  }
  if (g_strcmp0(name, "getSize") == 0) {
    gint width = 0, height = 0;
    gtk_window_get_size(window, &width, &height);
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(result, "width", fl_value_new_int(width));
    fl_value_set_string_take(result, "height", fl_value_new_int(height));
    fl_method_call_respond_success(method_call, result, nullptr);
    return;
  }
  if (g_strcmp0(name, "setSize") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    if (fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* width_value = fl_value_lookup_string(args, "width");
      FlValue* height_value = fl_value_lookup_string(args, "height");
      if (width_value != nullptr && height_value != nullptr) {
        gint width = fl_value_as_int(width_value);
        gint height = fl_value_as_int(height_value);
        // Resize now, and remember it as the default for a window that has
        // not been resized yet.
        gtk_window_set_default_size(window, width, height);
        gtk_window_resize(window, width, height);
        fl_method_call_respond_success(method_call, nullptr, nullptr);
        return;
      }
    }
  }
  fl_method_call_respond_not_implemented(method_call, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  // A second launch reaches the running instance through GApplication; it
  // brings the window back instead of opening another library.
  if (self->window != nullptr) {
    present_window(self);
    return;
  }
  // A queued Activate can arrive after the window died but before the engine
  // was torn down. Drop the old channels first so recreating them cannot
  // overwrite (and leak) channels still wired to the previous engine.
  g_clear_object(&self->theme_channel);
  g_clear_object(&self->window_channel);
  g_clear_object(&self->events_channel);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  g_signal_connect(window, "destroy", G_CALLBACK(window_destroy_cb), self);
  g_signal_connect(window, "focus-in-event", G_CALLBACK(window_focus_cb),
                   self);

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Omni Launcher");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Omni Launcher");
  }

  gtk_window_set_default_size(window, 1500, 950);
  gtk_widget_set_size_request(GTK_WIDGET(window), 900, 600);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#0E0E13");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Start dark (the launcher's default); Dart corrects this once it knows the
  // configured appearance mode.
  g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme",
               TRUE, nullptr);
  self->theme_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "omni_launcher/theme", FL_METHOD_CODEC(fl_standard_method_codec_new()));
  fl_method_channel_set_method_call_handler(
      self->theme_channel, theme_method_call_cb, g_object_ref(view),
      channel_user_data_destroy);
  self->window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "omni_launcher/window", FL_METHOD_CODEC(fl_standard_method_codec_new()));
  // The channel holds the application's lifetime here, not the other way
  // round: a ref'd self would form a cycle (application -> channel -> self)
  // that keeps dispose - and with it the engine teardown - from ever running.
  // main() keeps its own reference for as long as the process lives.
  fl_method_channel_set_method_call_handler(
      self->window_channel, window_method_call_cb, self, nullptr);
  // Outbound only: the runner tells Dart when the window comes back.
  self->events_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "omni_launcher/window_events",
      FL_METHOD_CODEC(fl_standard_method_codec_new()));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  // The window handler holds a raw self, so it must be unhooked while self is
  // still valid; clearing it first lets dispose proceed without the channel
  // keeping anything alive.
  if (self->window_channel != nullptr) {
    fl_method_channel_set_method_call_handler(self->window_channel, nullptr,
                                              nullptr, nullptr);
  }
  g_clear_object(&self->theme_channel);
  g_clear_object(&self->window_channel);
  g_clear_object(&self->events_channel);
  set_tray_icon(self, FALSE);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_DEFAULT_FLAGS, nullptr));
}
