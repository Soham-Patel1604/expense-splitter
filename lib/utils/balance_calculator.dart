import '../models/expense.dart';
import '../models/settlement.dart';

/// Pure money math shared by every screen (home, settle, insights, export),
/// so they can never disagree. Amounts are handled in whole paise internally
/// to avoid floating-point drift.

int _toPaise(double value) => (value * 100).round();

double _fromPaise(int paise) => paise / 100;

/// Rounds [value] to the nearest paisa.
double roundMoney(double value) => _fromPaise(_toPaise(value));

/// Splits [amount] equally among [userIds]. Leftover paise go one each to the
/// first participants, so the shares always add up to [amount] exactly.
Map<String, double> splitEqually(double amount, List<String> userIds) {
  if (userIds.isEmpty) return {};

  final total = _toPaise(amount);
  final base = total ~/ userIds.length;
  var leftover = total - base * userIds.length;

  final shares = <String, double>{};
  for (final userId in userIds) {
    var paise = base;
    if (leftover > 0) {
      paise++;
      leftover--;
    }
    shares[userId] = _fromPaise(paise);
  }
  return shares;
}

/// Rounds raw per-person amounts (unequal or percentage split) to the paisa
/// and gives any rounding leftover to the largest share, so the result adds up
/// to [amount] exactly. Zero or negative entries are dropped.
Map<String, double> fitSharesToTotal(
  double amount,
  Map<String, double> rawShares,
) {
  final paise = <String, int>{
    for (final entry in rawShares.entries)
      if (_toPaise(entry.value) > 0) entry.key: _toPaise(entry.value),
  };
  if (paise.isEmpty) return {};

  final diff = _toPaise(amount) - paise.values.fold<int>(0, (a, b) => a + b);
  if (diff != 0) {
    final largest = paise.entries
        .reduce((a, b) => b.value > a.value ? b : a)
        .key;
    paise[largest] = paise[largest]! + diff;
  }

  return paise.map((userId, p) => MapEntry(userId, _fromPaise(p)));
}

/// Splits [amount] by percentage (values in 0–100). Shares add up to
/// [amount] exactly even when the percentages produce fractional paise.
Map<String, double> splitByPercentages(
  double amount,
  Map<String, double> percentages,
) {
  return fitSharesToTotal(amount, {
    for (final entry in percentages.entries)
      entry.key: amount * entry.value / 100.0,
  });
}

/// Net position of every member in a group:
/// positive = the group owes them, negative = they owe the group.
///
/// The payer is credited the full amount and every participant (payer
/// included, if they took part) is debited their share. Settlements already
/// marked as paid move money from the payer back to the receiver.
Map<String, double> computeBalances({
  required Iterable<String> memberIds,
  required List<Expense> expenses,
  required List<Settlement> settlements,
}) {
  final paise = <String, int>{for (final id in memberIds) id: 0};

  for (final expense in expenses) {
    paise[expense.paidByUserId] =
        (paise[expense.paidByUserId] ?? 0) + _toPaise(expense.amount);
    expense.shares.forEach((userId, share) {
      paise[userId] = (paise[userId] ?? 0) - _toPaise(share);
    });
  }

  for (final settlement in settlements) {
    final amount = _toPaise(settlement.amount);
    paise[settlement.fromUserId] = (paise[settlement.fromUserId] ?? 0) + amount;
    paise[settlement.toUserId] = (paise[settlement.toUserId] ?? 0) - amount;
  }

  return paise.map((userId, p) => MapEntry(userId, _fromPaise(p)));
}

/// One suggested payment that moves a group toward settled.
class Transfer {
  final String fromUserId;
  final String toUserId;
  final double amount;

  const Transfer({
    required this.fromUserId,
    required this.toUserId,
    required this.amount,
  });
}

/// Greedy debt simplification: the biggest debtor pays the biggest creditor
/// until everyone is square. Ties are broken by user ID so suggestions stay
/// stable across refreshes.
List<Transfer> simplifyDebts(Map<String, double> balances) {
  final creditors = <MapEntry<String, int>>[];
  final debtors = <MapEntry<String, int>>[];

  balances.forEach((userId, balance) {
    final paise = _toPaise(balance);
    if (paise > 0) {
      creditors.add(MapEntry(userId, paise));
    } else if (paise < 0) {
      debtors.add(MapEntry(userId, -paise));
    }
  });

  int byAmountThenId(MapEntry<String, int> a, MapEntry<String, int> b) {
    final byAmount = b.value.compareTo(a.value);
    return byAmount != 0 ? byAmount : a.key.compareTo(b.key);
  }

  creditors.sort(byAmountThenId);
  debtors.sort(byAmountThenId);

  final transfers = <Transfer>[];
  var c = 0;
  var d = 0;

  while (c < creditors.length && d < debtors.length) {
    final creditor = creditors[c];
    final debtor = debtors[d];
    final paise = creditor.value < debtor.value ? creditor.value : debtor.value;

    transfers.add(
      Transfer(
        fromUserId: debtor.key,
        toUserId: creditor.key,
        amount: _fromPaise(paise),
      ),
    );

    creditors[c] = MapEntry(creditor.key, creditor.value - paise);
    debtors[d] = MapEntry(debtor.key, debtor.value - paise);
    if (creditors[c].value == 0) c++;
    if (debtors[d].value == 0) d++;
  }

  return transfers;
}
