/// Model representing a member in a group with their payment details
class GroupMember {
  final String userId;
  final String userName;
  final double amountPaid;

  GroupMember({
    required this.userId,
    required this.userName,
    required this.amountPaid,
  });
}
