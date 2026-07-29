import 'package:supabase/supabase.dart';

class DatabaseService {
  static late SupabaseClient client;

  static void init() {
    const supabaseUrl =
        'https://gwafzhdtrqvwakawjmwm.supabase.co'; // استبدل هنا
    const supabaseKey =
        'sb_publishable_gomM_R_xF7mG4hHuFblFmQ_RG6ZXSB-'; // استبدل هنا

    client = SupabaseClient(supabaseUrl, supabaseKey);
  }
}
