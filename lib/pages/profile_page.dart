import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../database/database.dart';
import '../models/user.dart';
import '../repositories/user_repository.dart';
import '../theme/app_theme.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  late UserRepository _userRepository;
  User? _currentUser;
  bool _isLoading = true;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final database = AppDatabase();
    _userRepository = UserRepository(database: database);
    _loadUserProfile();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _loadUserProfile() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final currentUserId = prefs.getString('currentUserId');

      if (currentUserId == null) {
        setState(() {
          _errorMessage = 'No active user session found.';
          _isLoading = false;
        });
        return;
      }

      final user = await _userRepository.getUserById(currentUserId);
      if (!mounted) return;

      if (user == null) {
        setState(() {
          _errorMessage = 'User profile not found.';
          _isLoading = false;
        });
        return;
      }

      setState(() {
        _currentUser = user;
        _nameController.text = user.name;
        _phoneController.text = user.phone ?? '';
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to load profile: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate() || _currentUser == null) {
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final updatedName = normalizeName(_nameController.text);
      final updatedPhone = _phoneController.text.trim();

      // Names identify people on this device, so two profiles can't share one.
      if (await _userRepository.isNameTaken(
        updatedName,
        excludingUserId: _currentUser!.id,
      )) {
        if (!mounted) return;
        setState(() {
          _errorMessage =
              '"$updatedName" is already used by someone else on this device.';
          _isSaving = false;
        });
        return;
      }

      final updatedUser = User(
        id: _currentUser!.id,
        name: updatedName,
        phone: updatedPhone.isEmpty ? null : updatedPhone,
        createdAt: _currentUser!.createdAt,
      );

      await _userRepository.updateUser(updatedUser);

      if (mounted) {
        final ColorScheme colorScheme = Theme.of(context).colorScheme;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: colorScheme.onInverseSurface),
                const SizedBox(width: 8),
                const Text('Profile updated successfully'),
              ],
            ),
            duration: const Duration(seconds: 2),
          ),
        );

        // Pop back to GroupsListPage and pass true to trigger reload
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to update profile: ${e.toString()}';
        _isSaving = false;
      });
    }
  }

  String _formatDate(int timestamp) {
    if (timestamp <= 0) return 'Unknown';
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final year = dt.year;
    return '$day/$month/$year';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // AppBar takes its surface/onSurface colors from the global theme.
      appBar: AppBar(),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    final TextTheme textTheme = theme.textTheme;

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null && _currentUser == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48, color: colorScheme.error),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _loadUserProfile,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final initialLetter = (_currentUser?.name.isNotEmpty ?? false)
        ? _currentUser!.name[0].toUpperCase()
        : 'U';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Intro block — screen title (32) + one friendly helper line (16).
            Text('Edit Profile', style: textTheme.displayLarge),
            const SizedBox(height: 8),
            Text(
              'Update your name and phone number.',
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),

            // Avatar — the page's one warm accent (10% rule).
            Center(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: AppTheme.warmAccent,
                  shape: BoxShape.circle,
                ),
                child: CircleAvatar(
                  radius: 46,
                  backgroundColor: colorScheme.primary,
                  child: Text(
                    initialLetter,
                    style: textTheme.displayLarge?.copyWith(
                      color: colorScheme.onPrimary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Member info — theme Card, meta text in label styles.
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Column(
                      children: [
                        Text('Member Since', style: textTheme.labelMedium),
                        const SizedBox(height: 8),
                        Text(
                          _formatDate(_currentUser?.createdAt ?? 0),
                          style: textTheme.labelLarge,
                        ),
                      ],
                    ),
                    const SizedBox(
                      height: 32,
                      child: VerticalDivider(width: 1),
                    ),
                    Column(
                      children: [
                        Text('Account ID', style: textTheme.labelMedium),
                        const SizedBox(height: 8),
                        Text(
                          _currentUser != null && _currentUser!.id.length >= 8
                              ? '${_currentUser!.id.substring(0, 8)}...'
                              : 'Local User',
                          style: textTheme.labelLarge,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Name field — global InputDecorationTheme handles the borders.
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Full Name *',
                hintText: 'Enter your full name',
                prefixIcon: Icon(Icons.person_outline),
              ),
              textCapitalization: TextCapitalization.words,
              enabled: !_isSaving,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Name is required';
                }
                return null;
              },
            ),
            const SizedBox(height: 24),

            // Phone field
            TextFormField(
              controller: _phoneController,
              decoration: const InputDecoration(
                labelText: 'Phone Number (Optional)',
                hintText: 'Enter your phone number',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
              keyboardType: TextInputType.phone,
              enabled: !_isSaving,
            ),
            const SizedBox(height: 24),

            // Save failure banner
            if (_errorMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: colorScheme.onErrorContainer,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Save action — themed ElevatedButton, full width, thumb zone.
            SizedBox(
              width: double.infinity,
              child: _isSaving
                  ? ElevatedButton(
                      onPressed: null,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                      ),
                      child: SizedBox(
                        height: 24,
                        width: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.onPrimary,
                        ),
                      ),
                    )
                  : ElevatedButton.icon(
                      onPressed: _saveProfile,
                      icon: const Icon(Icons.check),
                      label: const Text('Save Changes'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                      ),
                    ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
