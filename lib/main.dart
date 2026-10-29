import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:io';
import 'database/database.dart';
import 'pages/login_page.dart';
import 'pages/groups_list_page.dart';
import 'repositories/user_repository.dart';
import 'theme/app_theme.dart';

/// Global notifier to manage and notify theme mode changes across the app
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier<ThemeMode>(
  ThemeMode.system,
);

/// Updates the active theme mode and persists the preference to SharedPreferences
Future<void> updateThemeMode(ThemeMode mode) async {
  themeNotifier.value = mode;
  final prefs = await SharedPreferences.getInstance();
  String value;
  switch (mode) {
    case ThemeMode.light:
      value = 'light';
      break;
    case ThemeMode.dark:
      value = 'dark';
      break;
    case ThemeMode.system:
      value = 'system';
      break;
  }
  await prefs.setString('themeMode', value);
}

/// Removes the Material 3 overscroll stretch animation (and glow) app-wide.
/// Applied once via MaterialApp.scrollBehavior, so every page inherits it —
/// no per-page physics edits needed.
class NoStretchScrollBehavior extends MaterialScrollBehavior {
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load saved theme preference
  try {
    final prefs = await SharedPreferences.getInstance();
    final savedTheme = prefs.getString('themeMode') ?? 'system';
    if (savedTheme == 'light') {
      themeNotifier.value = ThemeMode.light;
    } else if (savedTheme == 'dark') {
      themeNotifier.value = ThemeMode.dark;
    } else {
      themeNotifier.value = ThemeMode.system;
    }
  } catch (e) {
    debugPrint('Error loading theme preference: $e');
  }

  // Initialize sqflite based on platform
  if (!kIsWeb) {
    // Only use FFI for desktop platforms (Windows, macOS, Linux)
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    // For Android and iOS, sqflite works natively without FFI

    await _mergeDuplicateUsersOnce();
  }

  runApp(const MyApp());
}

/// Older versions created a new person on every login and for every friend
/// added without a phone, which scattered one person's events across several
/// profiles. Folding them together once lets a login by name bring all of
/// those events back.
Future<void> _mergeDuplicateUsersOnce() async {
  const doneKey = 'duplicateUsersMerged';
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(doneKey) ?? false) return;

    final currentUserId = prefs.getString('currentUserId');
    final merged = await UserRepository(
      database: AppDatabase(),
    ).mergeDuplicateUsers(preferredUserId: currentUserId);

    final mergedInto = merged[currentUserId];
    if (mergedInto != null) {
      await prefs.setString('currentUserId', mergedInto);
    }
    await prefs.setBool(doneKey, true);
  } catch (e) {
    debugPrint('Error merging duplicate users: $e');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, currentMode, _) {
        return MaterialApp(
          title: 'Expense Splitter',
          themeMode: currentMode,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          scrollBehavior: NoStretchScrollBehavior(),
          debugShowCheckedModeBanner: false,
          home: kIsWeb ? const WebFallbackPage() : const AppEntry(),
        );
      },
    );
  }
}

class WebFallbackPage extends StatelessWidget {
  const WebFallbackPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Expense Splitter')),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.laptop_chromebook,
                  size: 64,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 24),
                Text(
                  'Expense Splitter',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Web Demo Mode',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 32),
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSecondaryContainer,
                        size: 32,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Local Storage Required',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSecondaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This app requires local database storage to work properly. '
                        'For full functionality, please download and run on:',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _buildPlatformChip(context, Icons.android, 'Android'),
                    _buildPlatformChip(context, Icons.phone_iphone, 'iOS'),
                    _buildPlatformChip(
                      context,
                      Icons.laptop_windows,
                      'Windows',
                    ),
                    _buildPlatformChip(context, Icons.laptop_mac, 'macOS'),
                    _buildPlatformChip(context, Icons.laptop, 'Linux'),
                  ],
                ),
                const SizedBox(height: 32),
                ElevatedButton.icon(
                  onPressed: () {
                    // Could navigate to a demo version or download page
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Please download the native app for full functionality',
                        ),
                        duration: Duration(seconds: 3),
                      ),
                    );
                  },
                  icon: const Icon(Icons.download),
                  label: const Text('Get Native App'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlatformChip(BuildContext context, IconData icon, String label) {
    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      labelStyle: TextStyle(
        color: Theme.of(context).colorScheme.onPrimaryContainer,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

class AppEntry extends StatelessWidget {
  const AppEntry({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _checkIfUserExists(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // If user exists, show GroupsListPage, otherwise show LoginPage
        if (snapshot.data ?? false) {
          return const GroupsListPage();
        } else {
          return const LoginPage();
        }
      },
    );
  }

  Future<bool> _checkIfUserExists() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('currentUserId');
      if (userId == null) return false;

      // A session pointing at a profile that no longer exists is logged out.
      final user = await UserRepository(
        database: AppDatabase(),
      ).getUserById(userId);
      if (user == null) {
        await prefs.remove('currentUserId');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('Error checking user: $e');
      return false;
    }
  }
}
