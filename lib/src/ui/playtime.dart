/// Playtime wording for the detail panel.
///
/// Pure formatting only: the accumulation lives with the store that persists
/// it, so these helpers can be tested without a launcher or a file.
library;

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Total time played, rounded down to the minute: `0m`, `45m`, `3h`, `12h 40m`.
///
/// Rounded down on purpose: an interrupted session should never look longer
/// than it was.
String formatPlaytime(Duration total) {
  final minutes = total.inMinutes;
  if (minutes <= 0) return '0m';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (hours == 0) return '${rest}m';
  if (rest == 0) return '${hours}h';
  return '${hours}h ${rest}m';
}

/// When a game was last played, relative to [now]: `today`, `yesterday`,
/// `3 days ago`, `2 weeks ago`, or `on 12 Mar 2026` past a month.
///
/// Both timestamps are read in the local calendar, so a stored UTC instant
/// lands on the day the player saw. A timestamp in the future (a clock that
/// moved backwards) reads as `today` rather than a negative age.
String formatLastPlayed(DateTime lastPlayed, DateTime now) {
  final days = _calendarDaysBetween(lastPlayed.toLocal(), now.toLocal());
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 7) return '$days days ago';
  if (days < 30) {
    final weeks = days ~/ 7;
    return weeks == 1 ? 'a week ago' : '$weeks weeks ago';
  }
  final date = lastPlayed.toLocal();
  return 'on ${date.day} ${_months[date.month - 1]} ${date.year}';
}

/// Whole calendar days from [from] to [to], counted on the local date.
int _calendarDaysBetween(DateTime from, DateTime to) {
  final start = DateTime(from.year, from.month, from.day);
  final end = DateTime(to.year, to.month, to.day);
  // Hours, not `inDays`: a DST change makes one of the days 23 or 25 hours.
  return (end.difference(start).inHours / 24).round();
}
