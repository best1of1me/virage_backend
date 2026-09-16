import 'dart:io';
import 'package:supabase/supabase.dart';

class DatabaseService {
  static late SupabaseClient client;

  static void init() {
    final supabaseUrl =
        Platform.environment['SUPABASE_URL'] ??
        'https://gwafzhdtrqvwakawjmwm.supabase.co';

    final supabaseKey = Platform.environment['SUPABASE_SERVICE_ROLE_KEY'];
    if (supabaseKey == null || supabaseKey.isEmpty) {
      throw StateError('SUPABASE_SERVICE_ROLE_KEY غير مضبوط في بيئة التشغيل');
    }

    client = SupabaseClient(supabaseUrl, supabaseKey);
  }
}
