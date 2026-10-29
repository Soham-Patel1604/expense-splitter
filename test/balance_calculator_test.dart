import 'package:flutter_test/flutter_test.dart';

import 'package:expense_splitter/models/expense.dart';
import 'package:expense_splitter/models/settlement.dart';
import 'package:expense_splitter/utils/balance_calculator.dart';
import 'package:expense_splitter/utils/currency.dart';

Expense _expense(String payer, double amount, Map<String, double> shares) {
  return Expense(
    id: 'e',
    groupId: 'g',
    amount: amount,
    paidByUserId: payer,
    paidByUserName: payer,
    participantIds: shares.keys.toList(),
    participantNames: shares.keys.toList(),
    shares: shares,
    createdAt: 0,
  );
}

double _sum(Map<String, double> m) => m.values.fold(0.0, (a, b) => a + b);

void main() {
  group('splitting', () {
    test('equal split hands out leftover paise and sums exactly', () {
      final shares = splitEqually(100, ['a', 'b', 'c']);
      expect(shares, {'a': 33.34, 'b': 33.33, 'c': 33.33});
      expect(_sum(shares), closeTo(100, 1e-9));
    });

    test('percentage split sums exactly to the amount', () {
      final shares = splitByPercentages(1000, {'a': 33.33, 'b': 33.33, 'c': 33.34});
      expect(_sum(shares), closeTo(1000, 1e-9));
      expect(shares['c'], 333.4);
    });

    test('fitSharesToTotal drops zero shares and absorbs rounding', () {
      final shares = fitSharesToTotal(10, {'a': 3.333, 'b': 6.667, 'c': 0});
      expect(shares.keys, ['a', 'b']);
      expect(_sum(shares), closeTo(10, 1e-9));
    });
  });

  group('computeBalances', () {
    test('payer is credited even when not a participant', () {
      final balances = computeBalances(
        memberIds: ['p', 'a'],
        expenses: [_expense('p', 250, {'a': 250})],
        settlements: [],
      );
      expect(balances, {'p': 250, 'a': -250});
    });

    test('settlements move money back and balances always sum to zero', () {
      final balances = computeBalances(
        memberIds: ['p', 'a', 'b'],
        expenses: [_expense('p', 300, {'p': 100, 'a': 100, 'b': 100})],
        settlements: [
          Settlement(id: 's', groupId: 'g', fromUserId: 'a', fromUserName: 'a',
              toUserId: 'p', toUserName: 'p', amount: 100),
        ],
      );
      expect(balances, {'p': 100, 'a': 0, 'b': -100});
      expect(_sum(balances), 0);
    });
  });

  group('simplifyDebts', () {
    test('produces the minimal transfers for a simple chain', () {
      final transfers = simplifyDebts({'a': 100, 'b': -60, 'c': -40});
      expect(transfers, hasLength(2));
      expect(transfers.every((t) => t.toUserId == 'a'), isTrue);
      expect(transfers.map((t) => t.amount).toList(), [60, 40]);
    });

    test('a settled group needs no transfers', () {
      expect(simplifyDebts({'a': 0, 'b': 0}), isEmpty);
    });
  });

  group('currency (bug #4)', () {
    test('rupees only, with Indian digit grouping', () {
      expect(formatCurrency(150), '₹150.00');
      expect(formatCurrency(1234.5), '₹1,234.50');
      expect(formatCurrency(123456.5), '₹1,23,456.50');
      expect(formatCurrency(12345678), '₹1,23,45,678.00');
    });

    test('signed balances read the same everywhere', () {
      expect(formatSignedCurrency(250), '+₹250.00');
      expect(formatSignedCurrency(-250), '-₹250.00');
      expect(formatSignedCurrency(0), '₹0.00');
      expect(formatCurrency(-0.001), '₹0.00');
    });
  });
}
