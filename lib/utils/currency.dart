/// The app works in Indian Rupees only.
const String currencySymbol = '₹';

/// Formats [amount] in rupees with Indian digit grouping and 2 decimals.
///
/// Example:
/// ```dart
/// formatCurrency(150.0);     // '₹150.00'
/// formatCurrency(123456.5);  // '₹1,23,456.50'
/// formatCurrency(-250.0);    // '-₹250.00'
/// ```
String formatCurrency(double amount) {
  final paise = (amount.abs() * 100).round();
  final sign = amount < 0 && paise > 0 ? '-' : '';
  final rupees = _groupIndian(paise ~/ 100);
  final fraction = (paise % 100).toString().padLeft(2, '0');
  return '$sign$currencySymbol$rupees.$fraction';
}

/// Formats a balance with an explicit sign so "owed to you" and "you owe"
/// read the same way everywhere: '+₹250.00', '-₹250.00', '₹0.00'.
String formatSignedCurrency(double amount) {
  final paise = (amount * 100).round();
  if (paise > 0) return '+${formatCurrency(amount)}';
  if (paise < 0) return formatCurrency(amount);
  return formatCurrency(0);
}

/// 1234567 -> '12,34,567' (last three digits, then groups of two).
String _groupIndian(int value) {
  final digits = value.toString();
  if (digits.length <= 3) return digits;

  final lastThree = digits.substring(digits.length - 3);
  var rest = digits.substring(0, digits.length - 3);
  final groups = <String>[];
  while (rest.length > 2) {
    groups.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) groups.insert(0, rest);

  return '${groups.join(',')},$lastThree';
}
