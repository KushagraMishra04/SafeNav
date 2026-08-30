import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'screens/splash_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/destination_screen.dart';
import 'screens/safety_collection_screen.dart';
import 'screens/ai_analysis_screen.dart';
import 'screens/route_check_screen.dart';
import 'screens/navigation_screen.dart';
import 'screens/sos_screen.dart';
import 'screens/journey_end_screen.dart';
import 'screens/feedback_screen.dart';
import 'screens/database_update_screen.dart';

void main() {
  runApp(const AISafeRouteFinderApp());
}

class AISafeRouteFinderApp extends StatelessWidget {
  const AISafeRouteFinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeNav',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      initialRoute: '/',
      routes: {
        '/': (context) => const SplashScreen(),
        '/auth': (context) => const AuthScreen(),
        '/destination': (context) => const DestinationScreen(),
        '/collection': (context) => const SafetyCollectionScreen(),
        '/analysis': (context) => const AIAnalysisScreen(),
        '/routecheck': (context) => const RouteCheckScreen(),
        '/navigation': (context) => const NavigationScreen(),
        '/sos': (context) => const SOSScreen(),
        '/journeyend': (context) => const JourneyEndScreen(),
        '/feedback': (context) => const FeedbackScreen(),
        '/dbupdate': (context) => const DatabaseUpdateScreen(),
      },
    );
  }
}
