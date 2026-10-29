import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../database/database.dart';
import '../repositories/user_repository.dart';
import '../theme/app_theme.dart';
import 'groups_list_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLoading = false;
  String? _errorMessage;

  late UserRepository _userRepository;

  @override
  void initState() {
    super.initState();
    _userRepository = UserRepository(database: AppDatabase());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _handleContinue() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final name = _nameController.text.trim();
      final phone = _phoneController.text.trim();

      // Reuse the profile with this name (so its events come back) or
      // create a new one
      final login = await _userRepository.loginOrCreate(
        name,
        phone.isEmpty ? null : phone,
      );

      // Save current user ID to SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('currentUserId', login.id);

      if (mounted) {
        if (login.existed) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Welcome back, $name')),
          );
        }

        // Navigate to GroupsListPage
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const GroupsListPage()),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to create profile: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 32.0,
            ),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // One warm accent moment (the 10% color) above the greeting.
                  Container(
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppTheme.warmAccent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      Icons.waving_hand_rounded,
                      color: AppTheme.onWarm,
                      size: 26,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Welcome heading
                  Text('Welcome', style: theme.textTheme.displayLarge),
                  const SizedBox(height: 8),
                  Text(
                    "Let's set up your profile",
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Used this name before? Enter it again to get your '
                    'events back.',
                    style: theme.textTheme.labelMedium,
                  ),
                  const SizedBox(height: 32),

                  // Name TextField
                  Text(
                    'Name',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      hintText: 'Enter your name',
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Name is required';
                      }
                      return null;
                    },
                    enabled: !_isLoading,
                  ),
                  const SizedBox(height: 24),

                  // Phone TextField
                  Text(
                    'Phone (Optional)',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _phoneController,
                    decoration: const InputDecoration(
                      hintText: 'Enter your phone number',
                    ),
                    keyboardType: TextInputType.phone,
                    enabled: !_isLoading,
                  ),
                  const SizedBox(height: 32),

                  // Error message — tonal error surface, no hard borders
                  if (_errorMessage != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        _errorMessage!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                      ),
                    ),
                  if (_errorMessage != null) const SizedBox(height: 16),

                  // Continue button — full width, thumb zone, min 56px tall
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _handleContinue,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                      ),
                      child: _isLoading
                          ? SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: scheme.onPrimary,
                              ),
                            )
                          : const Text('Continue'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
