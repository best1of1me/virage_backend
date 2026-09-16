import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';
import 'code_generator.dart';
import 'db.dart';

class AppRouter {
  static String get _chargilySecretKey =>
      Platform.environment['CHARGILY_SECRET_KEY'] ??
      'test_sk_6mJk8N1EpuR1FCTdFWf5NocUq4jsrCjFxdD5HeZw';

  static String get _siteUrl =>
      Platform.environment['SITE_URL'] ?? 'https://example.com';

  static String get _apkVersionCode =>
      Platform.environment['APK_VERSION_CODE'] ?? '1';

  static String get _apkVersionName =>
      Platform.environment['APK_VERSION_NAME'] ?? '1.0.0';

  static String get _apkSha256 => Platform.environment['APK_SHA256'] ?? '';

  static String get _apkUrl => Platform.environment['APK_URL'] ??
      'https://github.com/best1of1me/virage_backend/releases/download/v$_apkVersionName/app-release.apk';

  static String get _apkDir => Platform.environment['APK_DIR'] ?? 'apk';

  Router get router {
    final app = Router();

    // Health Check
    app.get('/', (Request req) {
      return Response.ok(
        jsonEncode({
          'status': 'online',
          'message': 'Virage Backend is running',
        }),
        headers: {'content-type': 'application/json'},
      );
    });

    // 1. إنشاء رابط دفع (مع دعم خصم الإحالة 10% لأول عملية شراء)
    app.post('/api/create-checkout', (Request req) async {
      try {
        final bodyJson = await req.readAsString();
        final body = jsonDecode(bodyJson);
        final String? schoolId = body['school_id'];
        final int count = body['count'] ?? 10;
        final num baseAmount = body['amount'] ?? 2000;

        if (schoolId == null || schoolId.isEmpty) {
          return Response.badRequest(
            body: jsonEncode({'error': 'school_id مطلوب'}),
            headers: {'content-type': 'application/json'},
          );
        }

        num finalAmount = baseAmount;

        // التحقق مما إذا كانت المدرسة مسجلة عبر إحالة ولم تستفد من الخصم من قبل
        final referralCheck = await DatabaseService.client
            .from('referrals')
            .select('id, reward_granted')
            .eq('referee_id', schoolId)
            .maybeSingle();

        if (referralCheck != null && referralCheck['reward_granted'] == false) {
          finalAmount = baseAmount * 0.9; // خصم 10% على أول عملية شراء
        }

        final chargilyResponse = await http.post(
          Uri.parse('https://pay.chargily.net/test/api/v2/checkouts'),
          headers: {
            'Authorization': 'Bearer $_chargilySecretKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'amount': finalAmount,
            'currency': 'dzd',
            'success_url': '$_siteUrl/success',
            'failure_url': '$_siteUrl/failure',
            'metadata': {'school_id': schoolId, 'count': count},
          }),
        );

        if (chargilyResponse.statusCode == 200 ||
            chargilyResponse.statusCode == 201) {
          final resBody = jsonDecode(chargilyResponse.body);
          return Response.ok(
            jsonEncode({'checkout_url': resBody['checkout_url']}),
            headers: {'content-type': 'application/json'},
          );
        }

        return Response.internalServerError(
          body: jsonEncode({
            'error': 'فشل إنشاء عملية الدفع',
            'details': jsonDecode(chargilyResponse.body),
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

    // 2. استقبال إشعارات الدفع (Webhook مع منح مكافأة الإحالة)
    app.post('/api/webhook/chargily', (Request req) async {
      try {
        final rawBody = await req.readAsString();
        final signature =
            req.headers['x-chargily-signature'] ?? req.headers['signature'];

        print('Webhook Received. Signature Header: $signature');

        if (signature == null || !_verifySignature(rawBody, signature)) {
          print('Webhook Error: Signature verification failed!');
          return Response.forbidden(
            jsonEncode({'error': 'توقيع الطلب غير صالح'}),
            headers: {'content-type': 'application/json'},
          );
        }

        final event = jsonDecode(rawBody);
        print('Webhook Event Type: ${event['type']}');

        if (event['type'] == 'checkout.paid') {
          final checkout = event['data'] ?? {};
          final metadata = checkout['metadata'] ?? {};

          final String? schoolId = metadata['school_id']?.toString();
          final int count =
              int.tryParse(metadata['count']?.toString() ?? '10') ?? 10;

          if (schoolId == null || schoolId.isEmpty) {
            print('Webhook Error: school_id is missing in metadata');
            return Response.badRequest(
              body: jsonEncode({
                'error': 'school_id مفقود في البيانات الإضافية',
              }),
              headers: {'content-type': 'application/json'},
            );
          }

          // 1. توليد وإدراج أكواد التفعيل للمدرسة التي قامت بالشراء
          final List<Map<String, dynamic>> rowsToInsert = [];
          for (var i = 0; i < count; i++) {
            rowsToInsert.add({
              'code': CodeGenerator.generate(length: 8),
              'school_id': schoolId,
              'status': 'unused',
            });
          }

          print(
            'Inserting $count codes into database for school: $schoolId...',
          );
          await DatabaseService.client
              .from('activation_codes')
              .insert(rowsToInsert);
          print('Activation codes created successfully.');

          // 2. معالجة مكافأة الإحالة (منح 10 أكواد للمُحيل لمرة واحدة)
          final checkReferral = await DatabaseService.client
              .from('referrals')
              .select('id, referrer_id, reward_granted')
              .eq('referee_id', schoolId)
              .maybeSingle();

          if (checkReferral != null &&
              checkReferral['reward_granted'] == false) {
            final String referrerId = checkReferral['referrer_id'];

            final List<Map<String, dynamic>> bonusCodes = [];
            for (var i = 0; i < 5; i++) {
              bonusCodes.add({
                'code': CodeGenerator.generate(length: 8),
                'school_id': referrerId,
                'status': 'unused',
              });
            }

            // إدراج 10 أكواد هدية للمدرسة المُحيلة
            await DatabaseService.client
                .from('activation_codes')
                .insert(bonusCodes);

            // تحديث حالة المكافأة لتصبح ممنوحة حتى لا تكرر
            await DatabaseService.client
                .from('referrals')
                .update({'reward_granted': true})
                .eq('id', checkReferral['id']);

            print(
              'Referral reward granted successfully to referrer: $referrerId',
            );
          }
        }

        return Response.ok(
          jsonEncode({'status': 'success'}),
          headers: {'content-type': 'application/json'},
        );
      } on PostgrestException catch (pgError) {
        print('Supabase Postgrest Error during Webhook:');
        print('Message: ${pgError.message}');
        print('Details: ${pgError.details}');
        print('Hint: ${pgError.hint}');
        print('Code: ${pgError.code}');
        return Response.internalServerError(
          body: jsonEncode({
            'error': 'فشل الحفظ في قاعدة البيانات',
            'details': pgError.message,
            'code': pgError.code,
          }),
          headers: {'content-type': 'application/json'},
        );
      } catch (e, stackTrace) {
        print('Webhook General Exception: $e');
        print(stackTrace);
        return Response.internalServerError(
          body: jsonEncode({'error_details': e.toString()}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    // 3. توليد أكواد تفعيل يدويًا
    app.post('/api/generate', (Request req) async {
      try {
        final bodyJson = await req.readAsString();
        final body = jsonDecode(bodyJson);
        final String? schoolId = body['school_id'];
        final int count = body['count'] ?? 1;

        if (schoolId == null || schoolId.isEmpty) {
          return Response.badRequest(
            body: jsonEncode({'error': 'school_id مطلوب'}),
            headers: {'content-type': 'application/json'},
          );
        }

        final List<String> generatedCodes = [];
        final List<Map<String, dynamic>> rowsToInsert = [];

        for (var i = 0; i < count; i++) {
          final code = CodeGenerator.generate(length: 8);
          generatedCodes.add(code);
          rowsToInsert.add({
            'code': code,
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
      } on PostgrestException catch (pgError) {
        return Response.internalServerError(
          body: jsonEncode({
            'error': 'فشل إدخال الأكواد في قاعدة البيانات',
            'details': pgError.message,
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

    // 4. جلب قائمة الأكواد
    app.get('/api/codes', (Request req) async {
      try {
        final schoolId = req.url.queryParameters['school_id'];
        final status = req.url.queryParameters['status'];

        if (schoolId == null || schoolId.isEmpty) {
          return Response.badRequest(
            body: jsonEncode({'error': 'school_id مطلوب'}),
            headers: {'content-type': 'application/json'},
          );
        }

        var query = DatabaseService.client
            .from('activation_codes')
            .select('code, status, activated_at, created_at')
            .eq('school_id', schoolId);

        if (status != null && status.isNotEmpty) {
          query = query.eq('status', status);
        }

        final response = await query.order('created_at', ascending: false);

        return Response.ok(
          jsonEncode(response),
          headers: {'content-type': 'application/json'},
        );
      } on PostgrestException catch (pgError) {
        return Response.internalServerError(
          body: jsonEncode({'error_details': pgError.message}),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error_details': e.toString()}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    // 5. تفعيل الكود
    app.post('/api/activate', (Request req) async {
      try {
        final bodyJson = await req.readAsString();
        final body = jsonDecode(bodyJson);
        final String? code = body['code'];

        if (code == null || code.isEmpty) {
          return Response.badRequest(
            body: jsonEncode({'error': 'الكود مطلوب'}),
            headers: {'content-type': 'application/json'},
          );
        }

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

        if (check['status'] == 'activated') {
          return Response.badRequest(
            body: jsonEncode({'error': 'تم استخدام هذا الرمز من قبل'}),
            headers: {'content-type': 'application/json'},
          );
        }

        await DatabaseService.client
            .from('activation_codes')
            .update({
              'status': 'activated',
              'activated_at': DateTime.now().toIso8601String(),
            })
            .eq('code', code);

        return Response.ok(
          jsonEncode({'message': 'تم تفعيل الكود بنجاح'}),
          headers: {'content-type': 'application/json'},
        );
      } on PostgrestException catch (pgError) {
        return Response.internalServerError(
          body: jsonEncode({'error_details': pgError.message}),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error_details': e.toString()}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    // 6. فحص آخر إصدار للتطبيق (يستخدمه التطبيق وموقع الويب)
    app.get('/api/latest', (Request req) {
      return Response.ok(
        jsonEncode({
          'versionCode': int.tryParse(_apkVersionCode) ?? 1,
          'versionName': _apkVersionName,
          'url': _apkUrl,
          'sha256': _apkSha256,
          'changelogAr': 'الإصدار الأول من تطبيق Virage',
        }),
        headers: {
          'content-type': 'application/json',
          'cache-control': 'no-cache',
        },
      );
    });

    // 7. صفحات نتيجة الدفع (تخدمها الخلفية نفسها — لا حاجة لنطاق منفصل)
    app.get('/success', (Request req) {
      return _paymentPage(
        'تم الدفع بنجاح',
        'تم تسجيل عملية الشراء، ستصل الرموز إلى المدرسة خلال دقائق.',
        true,
      );
    });

    app.get('/failure', (Request req) {
      return _paymentPage(
        'تعذر إتمام الدفع',
        'لم تُؤكَّد العملية. يمكنك إعادة المحاولة في أي وقت.',
        false,
      );
    });

    // 8. تقديم ملف التحميل (APK) من مجلد apk/ على الخادم
    app.get('/apk/virage-<version>.apk', (Request req, String version) async {
      final file = File('$_apkDir${Platform.pathSeparator}virage-$version.apk');
      if (!await file.exists()) {
        return Response.notFound(
          jsonEncode({'error': 'ملف الإصدار $version غير متوفر بعد'}),
          headers: {'content-type': 'application/json'},
        );
      }
      final bytes = await file.readAsBytes();
      return Response.ok(
        bytes,
        headers: {
          'content-type': 'application/vnd.android.package-archive',
          'content-length': bytes.length.toString(),
          'cache-control': 'public, max-age=3600',
        },
      );
    });

    return app;
  }

  Response _paymentPage(String title, String message, bool success) {
    final body =
        '''
<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>
  body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #f4f6fb; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
  .card { background: #fff; border-radius: 16px; padding: 40px; max-width: 420px; text-align: center; box-shadow: 0 8px 30px rgba(0,0,0,0.08); }
  .icon { font-size: 56px; }
  h1 { color: #1f2937; margin: 16px 0 8px; font-size: 22px; }
  p { color: #6b7280; line-height: 1.7; }
</style>
</head>
<body>
<div class="card">
  <div class="icon">${success ? '✅' : '⚠️'}</div>
  <h1>$title</h1>
  <p>$message</p>
</div>
</body>
</html>''';
    return Response.ok(
      body,
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  }

  bool _verifySignature(String payload, String signature) {
    final hmac = Hmac(sha256, utf8.encode(_chargilySecretKey));
    final digest = hmac.convert(utf8.encode(payload));
    return digest.toString() == signature;
  }
}
