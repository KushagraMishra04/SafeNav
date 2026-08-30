/// Very small in-memory "state manager" for the prototype.
/// Good enough for a demo — swap for Provider/Riverpod/Bloc later.
class AppState {
  AppState._();
  static final AppState instance = AppState._();

  String userName = '';
  String destination = '';
  int safetyScore = 0; // 0-100
  int crowdConfidence = 0;
  int lightingConfidence = 0;
  int dataConfidence = 0;
  String helpAvailability = 'Medium';
  int routeRecalculations = 0;
  int sosAlertsTriggered = 0;
  double userRating = 0;
  String feedbackText = '';

  void resetForNewJourney() {
    destination = '';
    safetyScore = 0;
    crowdConfidence = 0;
    lightingConfidence = 0;
    dataConfidence = 0;
    helpAvailability = 'Medium';
    routeRecalculations = 0;
    sosAlertsTriggered = 0;
    userRating = 0;
    feedbackText = '';
  }
}
