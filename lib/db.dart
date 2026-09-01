import 'dart:io';
import 'package:supabase/supabase.dart';

class DatabaseService {
  static late SupabaseClient client;

  static void init() {
    final supabaseUrl =
        Platform.environment['SUPABASE_URL'] ??
        'https://gwafzhdtrqvwakawjmwm.supabase.co';

    // ألصق مفتاح service_role الذي نسخته هنا بين التنصيص
    final supabaseKey =
        Platform.environment['SUPABASE_SERVICE_ROLE_KEY'] ??
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imd3YWZ6aGR0cnF2d2FrYXdqbXdtIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4NTE2ODI4MywiZXhwIjoyMTAwNzQ0MjgzfQ.5g1IC-m-qyoy_qtqksJ98skd3Kj14yoOL2mBPj5-YwM';

    client = SupabaseClient(supabaseUrl, supabaseKey);
  }
}
