import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:url_launcher/url_launcher.dart';

class AlertResult {
  final int sent, failed;
  final String? problem;
  const AlertResult(this.sent, this.failed, this.problem);
}

/// Fallback without an SMS plugin: texts open in the message app (the person taps send).
/// The call to 112 is still placed directly.
class Emergency {
  static Future<bool> prepare() async => false;

  static Future<AlertResult> sendAll(List<String> contacts, String message) async =>
      AlertResult(0, contacts.length, 'silent SMS plugin not installed');

  static Future<bool> call(String number) async {
    try {
      final ok = await FlutterPhoneDirectCaller.callNumber(number);
      if (ok == true) return true;
    } catch (_) {}
    return launchUrl(Uri.parse('tel:$number'));
  }

  static Future<bool> dial(String number) => launchUrl(Uri.parse('tel:$number'));

  /// Open SMS app directly addressed to emergency number (e.g. 112) with prefilled message
  static Future<bool> sendSms(String number, String message) async {
    try {
      final uri = Uri.parse('sms:$number?body=${Uri.encodeComponent(message)}');
      return await launchUrl(uri);
    } catch (_) {
      return false;
    }
  }
}
