import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'code_generator.dart';
import 'db.dart';

class AppRouter {
  Router get router {
    final app = Router();

    // 1. توليد أكواد تفعيل جديدة (لصالح مدرسة سياقة)
    // توليد أكواد تفعيل رقمية وفريدة
    app.post('/api/generate', (Request req) async {
      try {
        final bodyJson = await req.readAsString();
        final body = jsonDecode(bodyJson);
        final String? schoolId = body['school_id'];
        final int count = body['count'] ?? 1;

        if (schoolId == null) {
          return Response.badRequest(
            body: jsonEncode({'error': 'school_id مطلوب'}),
            headers: {'content-type': 'application/json'},
          );
        }

        final List<String> generatedCodes = [];
        final List<Map<String, dynamic>> rowsToInsert = [];

        // جلب جميع الأكواد الحالية لتجنب التكرار
        final existingRows = await DatabaseService.client
            .from('activation_codes')
            .select('code');

        final Set<String> existingCodes = (existingRows as List)
            .map((e) => e['code'].toString())
            .toSet();

        for (var i = 0; i < count; i++) {
          String newCode;
          // تكرار المحاولة في حال صادف كوداً مكرراً بالصدفة
          do {
            newCode = CodeGenerator.generate(length: 8);
          } while (existingCodes.contains(newCode) ||
              generatedCodes.contains(newCode));

          generatedCodes.add(newCode);
          rowsToInsert.add({
            'code': newCode,
            'school_id': schoolId,
            'status': 'unused',
          });
        }

        await DatabaseService.client
            .from('activation_codes')
            .insert(rowsToInsert);

        return Response.ok(
          jsonEncode({
            'message': 'تم توليد الأكواد بنجاح',
            'codes': generatedCodes,
          }),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error_details': e.toString()}),
          headers: {'content-type': 'application/json'},
        );
      }
    });
    // 2. جلب قائمة الأكواد الخاصة بمدرسة سياقة محددة
    app.get('/api/codes', (Request req) async {
      final schoolId = req.url.queryParameters['school_id'];
      final status = req.url.queryParameters['status'];

      if (schoolId == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'school_id مطلوب'}),
          headers: {'content-type': 'application/json'},
        );
      }

      var query = DatabaseService.client
          .from('activation_codes')
          .select('code, status, student_phone, activated_at, created_at')
          .eq('school_id', schoolId);

      if (status != null && status.isNotEmpty) {
        query = query.eq('status', status);
      }

      final response = await query.order('created_at', ascending: false);

      return Response.ok(
        jsonEncode(response),
        headers: {'content-type': 'application/json'},
      );
    });

    // 3. تفعيل الكود من طرف تطبيق الهواتف (Virage)
    app.post('/api/activate', (Request req) async {
      final body = jsonDecode(await req.readAsString());
      final String? code = body['code'];
      final String? studentPhone = body['student_phone'];

      if (code == null || studentPhone == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'الكود ورقم الهاتف مطلوبان'}),
          headers: {'content-type': 'application/json'},
        );
      }

      // البحث عن حالة الكود
      final check = await DatabaseService.client
          .from('activation_codes')
          .select('status')
          .eq('code', code)
          .maybeSingle();

      if (check == null) {
        return Response.notFound(
          jsonEncode({'error': 'رمز التفعيل غير صحيح'}),
          headers: {'content-type': 'application/json'},
        );
      }

      if (check['status'] == 'active') {
        return Response.badRequest(
          body: jsonEncode({'error': 'تم استخدام هذا الرمز من قبل'}),
          headers: {'content-type': 'application/json'},
        );
      }

      // تحديث حالة الكود
      await DatabaseService.client
          .from('activation_codes')
          .update({
            'status': 'active',
            'student_phone': studentPhone,
            'activated_at': DateTime.now().toIso8601String(),
          })
          .eq('code', code);

      return Response.ok(
        jsonEncode({'message': 'تم تفعيل الحساب بنجاح'}),
        headers: {'content-type': 'application/json'},
      );
    });

    return app;
  }
}
