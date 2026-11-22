import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:adhan_dart/adhan_dart.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

import 'data.dart';
import 'extra_pages.dart';

const Color forest = Color(0xFF087B53);
const Color deepGreen = Color(0xFF07583F);
const Color mint = Color(0xFFE9F5EF);
const Color gold = Color(0xFFC7A75B);
const Color ink = Color(0xFF20352C);
const String appName = 'سَكينة';
const String quranApi = 'https://api.alquran.cloud/v1';
const String adhanUrl = 'https://upload.wikimedia.org/wikipedia/commons/b/b0/Beautiful_adhan.ogg';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SakinahApp());
}

class QuranStore {
  static Future<Directory> _dir() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/quran');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _fullFile() async => File('${(await _dir()).path}/quran-uthmani.json');
  static Future<File> _surahFile(int number) async => File('${(await _dir()).path}/surah-$number.json');

  static Future<bool> hasFullQuran() async => (await _fullFile()).exists();

  static Future<void> downloadFull({required void Function(double) onProgress}) async {
    final response = await http.get(Uri.parse('$quranApi/quran/quran-uthmani')).timeout(const Duration(minutes: 2));
    if (response.statusCode != 200) throw Exception('تعذر تنزيل نص القرآن (${response.statusCode})');
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final data = decoded['data'];
    if (data is! Map || data['surahs'] is! List || (data['surahs'] as List).length != 114) {
      throw Exception('استجابة مصدر القرآن غير مكتملة');
    }
    final totalAyahs = (data['surahs'] as List).fold<int>(
      0,
      (sum, item) => sum + ((item as Map)['ayahs'] as List).length,
    );
    if (totalAyahs != 6236) {
      throw Exception('عدد آيات القرآن في الاستجابة غير مكتمل');
    }
    final file = await _fullFile();
    await file.writeAsBytes(response.bodyBytes, flush: true);
    onProgress(1);
  }

  static Future<List<dynamic>> loadSurah(int number) async {
    final full = await _fullFile();
    if (await full.exists()) {
      final decoded = jsonDecode(await full.readAsString()) as Map<String, dynamic>;
      final data = decoded['data'] as Map<String, dynamic>;
      final chapters = data['surahs'] as List<dynamic>;
      final match = chapters.cast<Map<String, dynamic>>().firstWhere((s) => s['number'] == number);
      return (match['ayahs'] as List<dynamic>);
    }
    final file = await _surahFile(number);
    if (await file.exists()) {
      final cached = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (cached['data']['ayahs'] as List<dynamic>);
    }
    final response = await http.get(Uri.parse('$quranApi/surah/$number/quran-uthmani')).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) throw Exception('تعذر تحميل السورة. تحقق من الاتصال بالإنترنت.');
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (decoded['data']?['ayahs'] is! List) throw Exception('بيانات السورة غير صحيحة');
    await file.writeAsBytes(response.bodyBytes, flush: true);
    return decoded['data']['ayahs'] as List<dynamic>;
  }
}

class AudioLibrary {
  static Future<Directory> _dir() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/audio');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> adhanFile() async => File('${(await _dir()).path}/adhan.ogg');

  static Future<void> downloadAdhan({required void Function(double) onProgress}) async {
    final response = await http.get(Uri.parse(adhanUrl)).timeout(const Duration(minutes: 2));
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) throw Exception('تعذر تنزيل ملف الأذان');
    final f = await adhanFile();
    await f.writeAsBytes(response.bodyBytes, flush: true);
    onProgress(1);
  }

  static Future<File> reciterDir(String edition) async {
    final dir = Directory('${(await _dir()).path}/recitations/$edition');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/.folder');
  }

  static String surahAudioUrl(int surah, String edition) =>
      'https://cdn.islamic.network/quran/audio-surah/128/$edition/$surah.mp3';

  static Future<void> downloadWholeQuran(String edition, {required void Function(int, int) onProgress}) async {
    final marker = await reciterDir(edition);
    final dir = marker.parent;
    for (var i = 1; i <= 114; i++) {
      final file = File('${dir.path}/${i.toString().padLeft(3, '0')}.mp3');
      if (!await file.exists() || await file.length() == 0) {
        final url = surahAudioUrl(i, edition);
        final r = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 3));
        if (r.statusCode != 200 || r.bodyBytes.length < 1000) throw Exception('فشل تنزيل سورة رقم $i');
        await file.writeAsBytes(r.bodyBytes, flush: true);
      }
      onProgress(i, 114);
    }
  }

  static Future<File?> downloadedSurah(String edition, int surah) async {
    final marker = await reciterDir(edition);
    final file = File('${marker.parent.path}/${surah.toString().padLeft(3, '0')}.mp3');
    return await file.exists() && await file.length() > 0 ? file : null;
  }
}

class SakinahApp extends StatelessWidget {
  const SakinahApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: forest, brightness: Brightness.light, surface: const Color(0xFFF7FAF8)),
        scaffoldBackgroundColor: const Color(0xFFF7FAF8),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFF7FAF8), foregroundColor: deepGreen, centerTitle: true, elevation: 0),
        cardTheme: CardThemeData(color: Colors.white, elevation: 0.8, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
        fontFamily: 'sans-serif',
      ),
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child ?? const SizedBox.shrink()),
      home: const MainShell(),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int tab = 0;
  final pages = const [HomePage(), QuranPage(), PrayerPage(), AzkarPage(), MorePage()];
  final labels = const ['الرئيسية', 'القرآن', 'الصلاة', 'الأذكار', 'المزيد'];
  final icons = const [Icons.home_rounded, Icons.menu_book_rounded, Icons.mosque_rounded, Icons.favorite_rounded, Icons.grid_view_rounded];
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: tab, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        backgroundColor: Colors.white,
        indicatorColor: mint,
        destinations: [for (var i = 0; i < labels.length; i++) NavigationDestination(icon: Icon(icons[i]), selectedIcon: Icon(icons[i], color: forest), label: labels[i])],
      ),
    );
  }
}

class SCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const SCard({super.key, required this.child, this.padding = const EdgeInsets.all(16)});
  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: padding, child: child));
}

class SectionTitle extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onTap;
  const SectionTitle(this.title, {super.key, this.action, this.onTap});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(3, 18, 3, 10),
    child: Row(children: [Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: deepGreen))), if (action != null) TextButton(onPressed: onTap, child: Text(action!))]),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String location = 'المكلا';
  int tasbih = 0;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) setState(() { location = p.getString('city') ?? 'المكلا'; tasbih = p.getInt('tasbih') ?? 0; });
  }
  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    return ListView(padding: const EdgeInsets.fromLTRB(18, 12, 18, 26), children: [
      Row(children: [Container(width: 46,height: 46,decoration: BoxDecoration(color: mint,borderRadius: BorderRadius.circular(15)),child: const Icon(Icons.nightlight_round,color: forest,size: 27)), const SizedBox(width: 10), const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,children: [Text('سَكينة',style: TextStyle(fontSize: 25,fontWeight: FontWeight.w900,color: deepGreen)),Text('طمأنينة لقلبك في كل يوم',style: TextStyle(color: Colors.black54,fontSize: 12))])), IconButton(onPressed: ()=>Navigator.push(context,MaterialPageRoute(builder: (_)=>const SettingsPage())),icon: const Icon(Icons.settings_outlined,color: forest))]),
      const SizedBox(height: 16),
      Container(padding: const EdgeInsets.all(20),decoration: BoxDecoration(gradient: const LinearGradient(colors:[deepGreen,forest]),borderRadius: BorderRadius.circular(25)),child: Column(crossAxisAlignment: CrossAxisAlignment.start,children:[Text(location,style: const TextStyle(color: Colors.white70)),const SizedBox(height:7),Text('${today.day}/${today.month}/${today.year} م',style: const TextStyle(color: Colors.white,fontSize: 18,fontWeight: FontWeight.bold)),Text('${toHijri(today).day} ${hijriMonths[toHijri(today).month]} ${toHijri(today).year} هـ · تاريخ تقريبي',style: const TextStyle(color: Colors.white70,fontSize: 12)),const SizedBox(height:13),const Text('﴿ أَلَا بِذِكْرِ اللَّهِ تَطْمَئِنُّ الْقُلُوبُ ﴾',style: TextStyle(color: Colors.white,fontSize: 20,height:1.8,fontWeight: FontWeight.w600)),const SizedBox(height:5),const Text('سورة الرعد · 28',style: TextStyle(color: Colors.white70))])),
      const SectionTitle('ابدأ يومك بالخير'),
      GridView.count(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisCount:2,mainAxisSpacing:10,crossAxisSpacing:10,childAspectRatio:1.55,children:[
        _HomeTile(icon:Icons.menu_book_rounded,title:'القرآن الكريم',subtitle:'اقرأ وتدبر',onTap:()=>Navigator.push(context,MaterialPageRoute(builder: (_)=>const QuranStandalonePage()))),
        _HomeTile(icon:Icons.access_time_rounded,title:'مواقيت الصلاة',subtitle:'أوقات اليوم',onTap:()=>Navigator.push(context,MaterialPageRoute(builder: (_)=>const PrayerStandalonePage()))),
        _HomeTile(icon:Icons.favorite_rounded,title:'الأذكار',subtitle:'حصن يومك',onTap:()=>Navigator.push(context,MaterialPageRoute(builder: (_)=>const AzkarStandalonePage()))),
        _HomeTile(icon:Icons.explore_rounded,title:'اتجاه القبلة',subtitle:'اعرف اتجاه صلاتك',onTap:()=>Navigator.push(context,MaterialPageRoute(builder: (_)=>const QiblaPage()))),
      ]),
      const SectionTitle('خطتك اليومية'),
      Row(children:[Expanded(child:_HomeTile(icon:Icons.menu_book_rounded,title:'خطة الختمة',subtitle:'تابع صفحاتك',onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const KhatmahPlannerPage())))),const SizedBox(width:10),Expanded(child:_HomeTile(icon:Icons.checklist_rounded,title:'عباداتي',subtitle:'سجّل إنجازك',onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const DailyWorshipPage()))))]),
      const SectionTitle('وردك اليومي'),
      SCard(child: Row(children:[Container(width:48,height:48,decoration:BoxDecoration(color:mint,borderRadius:BorderRadius.circular(15)),child:const Icon(Icons.circle_outlined,color:forest)),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('سبحتك اليوم',style:TextStyle(fontWeight:FontWeight.bold)),Text('$tasbih تسبيحة',style:const TextStyle(color:Colors.black54))])),FilledButton(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder: (_)=>const TasbihPage())),child:const Text('ابدأ'))])),
      const SectionTitle('أدعية مختارة'),
      SCard(child: Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('﴿ رَبَّنَا آتِنَا فِي الدُّنْيَا حَسَنَةً وَفِي الْآخِرَةِ حَسَنَةً وَقِنَا عَذَابَ النَّارِ ﴾',style:TextStyle(fontSize:19,height:1.9,color:ink)),const SizedBox(height:6),const Text('سورة البقرة · 201',style:TextStyle(color:forest,fontWeight:FontWeight.w700))])),
      const SizedBox(height:15),const Center(child:Text('تطوير وإنتاج: عبد العزيز عوض بن ثابت · © 2026',style:TextStyle(color:Colors.black45,fontSize:11))),
    ]);
  }
}

class _HomeTile extends StatelessWidget {
  final IconData icon; final String title,subtitle; final VoidCallback onTap;
  const _HomeTile({required this.icon,required this.title,required this.subtitle,required this.onTap});
  @override Widget build(BuildContext context)=>InkWell(onTap:onTap,borderRadius:BorderRadius.circular(19),child:Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(19),border:Border.all(color:const Color(0xFFE5EFE9))),child:Row(children:[Container(width:40,height:40,decoration:BoxDecoration(color:mint,borderRadius:BorderRadius.circular(13)),child:Icon(icon,color:forest)),const SizedBox(width:9),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisAlignment:MainAxisAlignment.center,children:[Text(title,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:13)),Text(subtitle,style:const TextStyle(color:Colors.black45,fontSize:10))]))])));
}

class QuranPage extends StatefulWidget { const QuranPage({super.key}); @override State<QuranPage> createState()=>_QuranPageState(); }
class _QuranPageState extends State<QuranPage> {
  String query=''; bool full=false; bool busy=false; double progress=0; String? error; int lastSurah = 0;
  @override void initState(){super.initState();_check();}
  Future<void> _check() async { final b=await QuranStore.hasFullQuran(); final prefs=await SharedPreferences.getInstance(); if(mounted)setState(() { full=b; lastSurah=prefs.getInt('quran_last_surah')??0; }); }
  Future<void> _download() async { setState(() { busy = true; error = null; progress = 0; }); try {await QuranStore.downloadFull(onProgress:(p){if(mounted)setState(()=>progress=p);}); if(mounted)setState(()=>full=true); _snack('تم حفظ نص القرآن الكريم كاملاً على جهازك');} catch(e){if(mounted)setState(()=>error=e.toString());} finally{if(mounted)setState(()=>busy=false);} }
  void _snack(String s)=>ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));
  @override Widget build(BuildContext context){final normalized=normalizeArabic(query); final filtered=surahs.where((s)=>normalizeArabic(s.name).contains(normalized)||s.number.toString()==query).toList(); return ListView(padding:const EdgeInsets.all(18),children:[Row(children:[const Expanded(child:Text('القرآن الكريم',style:TextStyle(fontSize:25,fontWeight:FontWeight.w900,color:deepGreen))),IconButton(tooltip:'البحث في القرآن',onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>QuranSearchPage(onOpenSurah:(number)=>Navigator.push(context,MaterialPageRoute(builder:(_)=>SurahPage(surah:surahs[number-1])))))),icon:const Icon(Icons.search,color:forest)),IconButton(tooltip:'علاماتي المحفوظة',onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>BookmarksPage(onOpenSurah:(number)=>Navigator.push(context,MaterialPageRoute(builder:(_)=>SurahPage(surah:surahs[number-1])))))),icon:const Icon(Icons.bookmark_outline,color:forest))]),const Text('كلام الله تعالى · 114 سورة',style:TextStyle(color:Colors.black54)),if(lastSurah>0)Padding(padding:const EdgeInsets.only(top:12),child:Card(child:ListTile(leading:const CircleAvatar(backgroundColor:mint,child:Icon(Icons.play_arrow_rounded,color:forest)),title:const Text('تابع آخر قراءة',style:TextStyle(fontWeight:FontWeight.bold)),subtitle:Text('سورة ${surahs[lastSurah-1].name}'),trailing:const Icon(Icons.chevron_left,color:forest),onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>SurahPage(surah:surahs[lastSurah-1])))))),const SizedBox(height:15),TextField(textDirection:TextDirection.rtl,decoration:InputDecoration(hintText:'ابحث عن سورة',prefixIcon:const Icon(Icons.search),filled:true,fillColor:Colors.white,border:OutlineInputBorder(borderRadius:BorderRadius.circular(16),borderSide:BorderSide.none)),onChanged:(v)=>setState(()=>query=v)),const SizedBox(height:12),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:mint,borderRadius:BorderRadius.circular(17)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[const Icon(Icons.download_for_offline_outlined,color:forest),const SizedBox(width:8),Expanded(child:Text(full?'نص القرآن محفوظ دون إنترنت':'نزّل نص القرآن كاملاً للعمل دون إنترنت',style:const TextStyle(fontWeight:FontWeight.bold,color:deepGreen))),if(full)const Icon(Icons.check_circle,color:forest)]),if(busy)Padding(padding:const EdgeInsets.only(top:10),child:LinearProgressIndicator(value:progress)),if(error!=null)Text(error!,style:const TextStyle(color:Colors.red)),if(!full&&!busy)Align(alignment:Alignment.centerLeft,child:TextButton.icon(onPressed:_download,icon:const Icon(Icons.download),label:const Text('تنزيل القرآن كاملاً')))])),const SizedBox(height:8),for(final s in filtered) Card(child:ListTile(leading:CircleAvatar(backgroundColor:mint,foregroundColor:forest,child:Text('${s.number}')),title:Text(s.name,style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text('${s.verses} آية · ${s.type}'),trailing:const Icon(Icons.chevron_left,color:forest),onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>SurahPage(surah:s)))),),const SizedBox(height:15),const Text('مصدر النص: AlQuran Cloud. يُعرض النص كما يرد من المصدر دون تعديل.',style:TextStyle(color:Colors.black45,fontSize:11))]);}
}

class SurahPage extends StatefulWidget {
  final SurahInfo surah;
  const SurahPage({super.key, required this.surah});
  @override
  State<SurahPage> createState() => _SurahPageState();
}

class _SurahPageState extends State<SurahPage> {
  List<dynamic>? ayahs;
  String? error;
  bool loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final result = await QuranStore.loadSurah(widget.surah.number);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('quran_last_surah', widget.surah.number);
      if (mounted) setState(() { ayahs = result; loading = false; });
    } catch (e) {
      if (mounted) setState(() { error = e.toString(); loading = false; });
    }
  }

  Future<void> _bookmark(Map<String, dynamic> ayah) async {
    await BookmarkStore.add({
      'surah': widget.surah.number,
      'surahName': widget.surah.name,
      'ayah': ayah['numberInSurah'],
      'text': ayah['text'],
    });
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ الآية في علاماتك')));
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return Scaffold(appBar: AppBar(title: Text('سورة ${widget.surah.name}')), body: const Center(child: CircularProgressIndicator(color: forest)));
    if (error != null) {
      return Scaffold(appBar: AppBar(title: Text('سورة ${widget.surah.name}')), body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(error!, textAlign: TextAlign.center), const SizedBox(height: 10), FilledButton(onPressed: () { setState(() { loading = true; error = null; }); _load(); }, child: const Text('إعادة المحاولة'))]))));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('سورة ${widget.surah.name}'),
        actions: [IconButton(tooltip: 'علاماتي المحفوظة', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BookmarksPage(onOpenSurah: (number) => Navigator.push(context, MaterialPageRoute(builder: (_) => SurahPage(surah: surahs[number - 1])))))), icon: const Icon(Icons.bookmark_outline))],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 26), children: [
        if (widget.surah.number != 1 && widget.surah.number != 9)
          const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Text('بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ', textAlign: TextAlign.center, style: TextStyle(fontSize: 25, color: deepGreen, height: 2))),
        Container(padding: const EdgeInsets.all(13), decoration: BoxDecoration(color: mint, borderRadius: BorderRadius.circular(16)), child: Text('سورة ${widget.surah.name} · ${widget.surah.verses} آية', textAlign: TextAlign.center, style: const TextStyle(color: deepGreen, fontWeight: FontWeight.bold))),
        const SizedBox(height: 12),
        for (final raw in ayahs!)
          Builder(builder: (context) {
            final ayah = Map<String, dynamic>.from(raw as Map);
            return Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 13, 14, 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('${ayah['text']} ﴿${ayah['numberInSurah']}﴾', textAlign: TextAlign.justify, style: const TextStyle(fontSize: 24, height: 2.05, color: ink)),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    IconButton(tooltip: 'حفظ الآية', onPressed: () => _bookmark(ayah), icon: const Icon(Icons.bookmark_add_outlined, color: forest)),
                    IconButton(tooltip: 'إنشاء بطاقة للآية', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AyahCardPage(ayahText: ayah['text'] as String, reference: 'سورة ${widget.surah.name} · الآية ${ayah['numberInSurah']}'))), icon: const Icon(Icons.image_outlined, color: forest)),
                  ]),
                ]),
              ),
            );
          }),
        const Divider(),
        const Text('النص من AlQuran Cloud ويُعرض كما ورد من المصدر دون تغيير.', style: TextStyle(fontSize: 11, color: Colors.black45)),
      ]),
    );
  }
}

class PrayerPage extends StatefulWidget {
  const PrayerPage({super.key});
  @override
  State<PrayerPage> createState() => _PrayerPageState();
}

class _PrayerPageState extends State<PrayerPage> {
  double lat = 14.5425, lon = 49.1242;
  String place = 'المكلا (إعداد افتراضي)';
  bool locating = false;
  List<MapEntry<String, DateTime>> times = [];
  MapEntry<String, DateTime>? nextPrayer;
  Timer? refreshTimer;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
    refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) => _calc());
  }

  @override
  void dispose() { refreshTimer?.cancel(); super.dispose(); }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      lat = prefs.getDouble('lat') ?? lat;
      lon = prefs.getDouble('lon') ?? lon;
      place = prefs.getString('city') ?? place;
    });
    _calc();
  }

  PrayerTimes _prayerTimes(DateTime date) {
    final params = CalculationMethodParameters.muslimWorldLeague()..madhab = Madhab.shafi;
    return PrayerTimes(coordinates: Coordinates(lat, lon), date: date, calculationParameters: params);
  }

  void _calc() {
    try {
      final now = DateTime.now();
      final pt = _prayerTimes(now);
      final todayTimes = <MapEntry<String, DateTime>>[
        MapEntry('الفجر', pt.fajr.toLocal()),
        MapEntry('الشروق', pt.sunrise.toLocal()),
        MapEntry('الظهر', pt.dhuhr.toLocal()),
        MapEntry('العصر', pt.asr.toLocal()),
        MapEntry('المغرب', pt.maghrib.toLocal()),
        MapEntry('العشاء', pt.isha.toLocal()),
      ];
      final actualPrayers = todayTimes.where((t) => t.key != 'الشروق').toList();
      MapEntry<String, DateTime>? next;
      for (final candidate in actualPrayers) {
        if (candidate.value.isAfter(now)) { next = candidate; break; }
      }
      next ??= MapEntry('الفجر', _prayerTimes(now.add(const Duration(days: 1))).fajr.toLocal());
      if (mounted) setState(() { times = todayTimes; nextPrayer = next; error = null; });
    } catch (e) {
      if (mounted) setState(() => error = 'تعذر حساب المواقيت: $e');
    }
  }

  Future<void> _locate() async {
    setState(() => locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw Exception('فعّل خدمة الموقع في الهاتف');
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) throw Exception('لم يتم السماح بالوصول للموقع');
      final pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('lat', pos.latitude);
      await prefs.setDouble('lon', pos.longitude);
      await prefs.setString('city', 'موقعي الحالي');
      if (!mounted) return;
      setState(() { lat = pos.latitude; lon = pos.longitude; place = 'موقعي الحالي'; });
      _calc();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  String fmt(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  String remaining(DateTime time) {
    final duration = time.difference(DateTime.now());
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    return hours > 0 ? 'باقي $hours ساعة و$minutes دقيقة' : 'باقي $minutes دقيقة';
  }

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(18), children: [
    const Text('مواقيت الصلاة', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900, color: deepGreen)),
    Text(place, style: const TextStyle(color: Colors.black54)),
    const SizedBox(height: 12),
    Container(padding: const EdgeInsets.all(19), decoration: BoxDecoration(gradient: const LinearGradient(colors: [deepGreen, forest]), borderRadius: BorderRadius.circular(23)), child: Column(children: [
      const Icon(Icons.mosque, color: Colors.white, size: 38),
      const SizedBox(height: 8),
      Text(DateTime.now().toLocal().toString().split(' ').first, style: const TextStyle(color: Colors.white70)),
      const Text('الصلاة القادمة', style: TextStyle(color: Colors.white70)),
      Text(nextPrayer?.key ?? '—', style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900)),
      if (nextPrayer != null) Text(fmt(nextPrayer!.value), style: const TextStyle(color: Colors.white, fontSize: 25, fontWeight: FontWeight.bold)),
      if (nextPrayer != null) Text(remaining(nextPrayer!.value), style: const TextStyle(color: Colors.white70)),
    ])),
    const SizedBox(height: 12),
    if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),
    for (final t in times) Card(child: ListTile(
      leading: CircleAvatar(backgroundColor: mint, child: Icon(Icons.access_time, color: forest)),
      title: Text(t.key, style: const TextStyle(fontWeight: FontWeight.bold)),
      trailing: Text(fmt(t.value), style: const TextStyle(fontSize: 18, color: deepGreen, fontWeight: FontWeight.bold)),
    )),
    const SizedBox(height: 8),
    FilledButton.icon(onPressed: locating ? null : _locate, icon: const Icon(Icons.my_location), label: Text(locating ? 'جارٍ تحديد الموقع' : 'تحديد موقعي بدقة')),
    const Text('طريقة الحساب: رابطة العالم الإسلامي · المذهب الشافعي. قد تختلف المواقيت دقائق حسب التقويم المحلي؛ راجع جهة الأوقاف أو المسجد في مدينتك.', style: TextStyle(color: Colors.black45, fontSize: 11, height: 1.6)),
  ]);
}

class AzkarPage extends StatefulWidget{const AzkarPage({super.key});@override State<AzkarPage> createState()=>_AzkarPageState();}
class _AzkarPageState extends State<AzkarPage>{int count=0;@override void initState(){super.initState();_load();}Future<void> _load()async{final p=await SharedPreferences.getInstance();if(mounted)setState(()=>count=p.getInt('tasbih')??0);}@override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.all(18),children:[const Text('الأذكار والسبحة',style:TextStyle(fontSize:25,fontWeight:FontWeight.w900,color:deepGreen)),const Text('أذكار مختارة مع مصدر كل ذكر',style:TextStyle(color:Colors.black54)),const SizedBox(height:12),for(var i=0;i<adhkar.length;i++)Card(child:ListTile(leading:CircleAvatar(backgroundColor:mint,foregroundColor:forest,child:Text('${i+1}')),title:Text(adhkar[i].title,style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text('${adhkar[i].count} مرة مقترحة'),trailing:const Icon(Icons.chevron_left,color:forest),onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>ZikrDetailPage(zikr:adhkar[i]))))),const SectionTitle('السبحة الإلكترونية'),SCard(child:Column(children:[Text('$count',style:const TextStyle(fontSize:34,fontWeight:FontWeight.w900,color:forest)),const Text('عداد هذه الجلسة'),const SizedBox(height:10),FilledButton.icon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const TasbihPage())),icon:const Icon(Icons.touch_app),label:const Text('افتح السبحة'))])),const SectionTitle('الأحاديث والأدعية'),FilledButton.tonal(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const HadithDuaPage())),child:const Text('تصفح الأحاديث والأدعية'))]);}

class ZikrDetailPage extends StatefulWidget{final Zikr zikr;const ZikrDetailPage({super.key,required this.zikr});@override State<ZikrDetailPage> createState()=>_ZikrDetailPageState();}
class _ZikrDetailPageState extends State<ZikrDetailPage>{int count=0;@override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text(widget.zikr.title)),body:Padding(padding:const EdgeInsets.all(22),child:Column(children:[const SizedBox(height:25),Text(widget.zikr.text,textAlign:TextAlign.center,style:const TextStyle(fontSize:24,height:2,color:ink)),const Spacer(),Text('العدد المقترح: ${widget.zikr.count}',style:const TextStyle(color:Colors.black54)),const SizedBox(height:12),Text('$count',style:const TextStyle(fontSize:52,color:forest,fontWeight:FontWeight.bold)),FilledButton(onPressed:()=>setState(()=>count=(count+1)% (widget.zikr.count+1)),style:FilledButton.styleFrom(minimumSize:const Size(150,70),shape:const CircleBorder()),child:const Icon(Icons.touch_app,size:34)),Text(widget.zikr.source,style:const TextStyle(color:Colors.black45)),const Spacer()])));}

class TasbihPage extends StatefulWidget{const TasbihPage({super.key});@override State<TasbihPage> createState()=>_TasbihPageState();}
class _TasbihPageState extends State<TasbihPage>{int count=0;@override void initState(){super.initState();_load();}Future<void> _load()async{final p=await SharedPreferences.getInstance();setState(()=>count=p.getInt('tasbih')??0);}Future<void> _increment()async{final p=await SharedPreferences.getInstance();setState(()=>count++);await p.setInt('tasbih',count);}Future<void> _reset()async{final p=await SharedPreferences.getInstance();setState(()=>count=0);await p.setInt('tasbih',0);}@override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('السبحة الإلكترونية')),body:Center(child:Padding(padding:const EdgeInsets.all(24),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[const Icon(Icons.spa,color:forest,size:45),const SizedBox(height:18),const Text('سبحان الله وبحمده',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold,color:deepGreen)),const SizedBox(height:12),Text('$count',style:const TextStyle(fontSize:70,color:forest,fontWeight:FontWeight.w900)),const SizedBox(height:15),FilledButton(onPressed:_increment,style:FilledButton.styleFrom(minimumSize:const Size(190,76),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(22))),child:const Text('تسبيح',style:TextStyle(fontSize:21))),TextButton.icon(onPressed:_reset,icon:const Icon(Icons.refresh),label:const Text('تصفير العداد'))]))));}

class MorePage extends StatelessWidget {
  const MorePage({super.key});
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(18), children: [
    const Text('المزيد', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900, color: deepGreen)),
    const SizedBox(height: 12),
    _MoreTile(icon: Icons.checklist_rounded, title: 'متابعة عباداتي', subtitle: 'الصلوات والورد والعادات اليومية', page: const DailyWorshipPage()),
    _MoreTile(icon: Icons.menu_book_rounded, title: 'خطة ختم القرآن', subtitle: 'اختر مدة الختمة وتابع تقدمك', page: const KhatmahPlannerPage()),
    _MoreTile(icon: Icons.search_rounded, title: 'البحث في القرآن', subtitle: 'ابحث داخل الآيات مع تطبيع الهمزات والتشكيل', page: QuranSearchPage(onOpenSurah: (number) => Navigator.push(context, MaterialPageRoute(builder: (_) => SurahPage(surah: surahs[number - 1]))))),
    _MoreTile(icon: Icons.bookmark_outline_rounded, title: 'علاماتي المحفوظة', subtitle: 'ارجع إلى الآيات التي حفظتها', page: BookmarksPage(onOpenSurah: (number) => Navigator.push(context, MaterialPageRoute(builder: (_) => SurahPage(surah: surahs[number - 1]))))),
    _MoreTile(icon: Icons.explore, title: 'اتجاه القبلة', subtitle: 'بوصلة نحو الكعبة', page: const QiblaPage()),
    _MoreTile(icon: Icons.headphones, title: 'التلاوات الصوتية', subtitle: 'خمسة قراء · تنزيل اختياري', page: const RecitersPage()),
    _MoreTile(icon: Icons.volume_up, title: 'الأذان الكامل', subtitle: 'تشغيل وتنزيل الأذان للاستماع دون إنترنت', page: const AdhanPage()),
    _MoreTile(icon: Icons.menu_book, title: 'الأحاديث والأدعية', subtitle: 'نصوص مختارة مع المراجع', page: const HadithDuaPage()),
    _MoreTile(icon: Icons.calendar_month, title: 'التقويم الهجري', subtitle: 'تاريخ هجري تقريبي', page: const HijriPage()),
    _MoreTile(icon: Icons.favorite_outline, title: 'ادعم تطوير التطبيق', subtitle: 'مساهمة اختيارية لتطوير سكينة', page: const SupportPage()),
    _MoreTile(icon: Icons.settings, title: 'الإعدادات', subtitle: 'الموقع وطريقة الاستخدام', page: const SettingsPage()),
    _MoreTile(icon: Icons.info_outline, title: 'عن التطبيق والمصادر', subtitle: 'الحقوق والمراجع والتراخيص', page: const AboutPage()),
  ]);
}

class _MoreTile extends StatelessWidget{final IconData icon;final String title,subtitle;final Widget page;const _MoreTile({required this.icon,required this.title,required this.subtitle,required this.page});@override Widget build(BuildContext context)=>Card(child:ListTile(leading:CircleAvatar(backgroundColor:mint,child:Icon(icon,color:forest)),title:Text(title,style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text(subtitle),trailing:const Icon(Icons.chevron_left,color:forest),onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>page))));}

class HadithDuaPage extends StatelessWidget {
  const HadithDuaPage({super.key});
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الأحاديث والأدعية'),
          bottom: const TabBar(tabs: [Tab(text: 'أحاديث نبوية'), Tab(text: 'أدعية')]),
        ),
        body: TabBarView(
          children: [
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final h in hadiths)
                  SCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(h.text, style: const TextStyle(fontSize: 20, height: 1.8, color: ink)),
                    const SizedBox(height: 8),
                    Text(h.source, style: const TextStyle(color: forest, fontWeight: FontWeight.bold, fontSize: 12)),
                  ])),
              ],
            ),
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final d in duas)
                  SCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(d.title, style: const TextStyle(fontWeight: FontWeight.bold, color: deepGreen, fontSize: 17)),
                    const SizedBox(height: 8),
                    Text(d.text, style: const TextStyle(fontSize: 20, height: 1.9, color: ink)),
                    const SizedBox(height: 7),
                    Text(d.source, style: const TextStyle(color: forest, fontSize: 12)),
                  ])),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class RecitersPage extends StatefulWidget{const RecitersPage({super.key});@override State<RecitersPage> createState()=>_RecitersPageState();}
class _RecitersPageState extends State<RecitersPage>{final player=AudioPlayer();StreamSubscription<PlayerState>? playerSub;int surah=1;String edition='ar.alafasy';bool playing=false,downloading=false;int done=0;String? status;@override void initState(){super.initState();playerSub=player.playerStateStream.listen((s){if(mounted)setState(()=>playing=s.playing);});}@override void dispose(){playerSub?.cancel();player.dispose();super.dispose();}Future<String> _audioUrl(int s,String e)async{return AudioLibrary.surahAudioUrl(s,e);}Future<void> _play()async{try{if(playing){await player.pause();if(mounted)setState(()=>playing=false);return;}final file=await AudioLibrary.downloadedSurah(edition,surah);if(file!=null){await player.setFilePath(file.path);}else{final url=await _audioUrl(surah,edition);await player.setUrl(url);}if(mounted)setState(()=>playing=true);unawaited(player.play());}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}}Future<void> _download()async{setState(() { downloading = true; done = 0; status = null; });try{await AudioLibrary.downloadWholeQuran(edition,onProgress:(d,t){if(mounted)setState(()=>done=d);});if(mounted)setState(()=>status='اكتمل تنزيل 114 سورة في مساحة التطبيق الخاصة');}catch(e){if(mounted)setState(()=>status=e.toString());}finally{if(mounted)setState(()=>downloading=false);}}@override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('التلاوات الصوتية')),body:ListView(padding:const EdgeInsets.all(18),children:[const Text('اختر القارئ',style:TextStyle(fontSize:24,fontWeight:FontWeight.w900,color:deepGreen)),const SizedBox(height:7),const Text('التسجيلات من AlQuran Cloud. اطلب التنزيل بنفسك للاحتفاظ بها داخل التطبيق دون اتصال.',style:TextStyle(color:Colors.black54)),const SizedBox(height:15),for(final r in reciters)Card(child:RadioListTile<String>(value:r['edition']!,groupValue:edition,title:Text(r['name']!,style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text(r['edition']!),activeColor:forest,onChanged:(v)=>setState(()=>edition=v!))),const SectionTitle('اختيار السورة'),DropdownButtonFormField<int>(value:surah,decoration:const InputDecoration(border:OutlineInputBorder(),filled:true,fillColor:Colors.white),items:[for(final s in surahs)DropdownMenuItem(value:s.number,child:Text('${s.number}. ${s.name}'))],onChanged:(v)=>setState(()=>surah=v??1)),const SizedBox(height:12),FilledButton.icon(onPressed:_play,icon:Icon(playing?Icons.pause:Icons.play_arrow),label:Text(playing?'تشغيل / إيقاف من المشغل':'استمع إلى السورة المختارة')),OutlinedButton.icon(onPressed:downloading?null:_download,icon:const Icon(Icons.download_for_offline),label:Text(downloading?'جارٍ تنزيل $done / 114':'تنزيل القرآن كاملاً لهذا القارئ')),if(downloading)LinearProgressIndicator(value:done/114),if(status!=null)Padding(padding:const EdgeInsets.all(8),child:Text(status!,style:const TextStyle(color:forest))),const SizedBox(height:10),const Text('ملاحظة: حجم التنزيل يختلف حسب القارئ. تحفظ التسجيلات داخل مساحة التطبيق الخاصة ولا يمكن تصديرها. حقوق التسجيلات لأصحابها؛ راجع صفحة المصادر.',style:TextStyle(color:Colors.black45,fontSize:11,height:1.6))]));}

class AdhanPage extends StatefulWidget{const AdhanPage({super.key});@override State<AdhanPage> createState()=>_AdhanPageState();}
class _AdhanPageState extends State<AdhanPage>{final player=AudioPlayer();StreamSubscription<PlayerState>? playerSub;bool playing=false,downloading=false,available=false;String? status;@override void initState(){super.initState();playerSub=player.playerStateStream.listen((s){if(mounted)setState(()=>playing=s.playing);});_check();}Future<void> _check()async{final f=await AudioLibrary.adhanFile();final exists=await f.exists();if(mounted)setState(()=>available=exists);}Future<void> _download()async{setState(()=>downloading=true);try{await AudioLibrary.downloadAdhan(onProgress:(_){ });if(mounted)setState(() { available = true; status = 'تم حفظ الأذان على جهازك'; });}catch(e){if(mounted)setState(()=>status=e.toString());}finally{if(mounted)setState(()=>downloading=false);}}Future<void> _toggle()async{try{if(playing){await player.pause();if(mounted)setState(()=>playing=false);return;}final f=await AudioLibrary.adhanFile();if(await f.exists()){await player.setFilePath(f.path);}else{await player.setUrl(adhanUrl);}if(mounted)setState(()=>playing=true);unawaited(player.play());}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('تعذر تشغيل الأذان: $e')));}}@override void dispose(){playerSub?.cancel();player.dispose();super.dispose();}@override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('الأذان الكامل')),body:Center(child:Padding(padding:const EdgeInsets.all(24),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[Container(width:150,height:150,decoration:const BoxDecoration(shape:BoxShape.circle,color:mint),child:const Icon(Icons.mosque,color:forest,size:72)),const SizedBox(height:22),const Text('الأذان',style:TextStyle(fontSize:27,fontWeight:FontWeight.w900,color:deepGreen)),const SizedBox(height:8),const Text('تسجيل مرخّص برخصة CC0 من Wikimedia Commons.',textAlign:TextAlign.center,style:TextStyle(color:Colors.black54)),const SizedBox(height:20),FilledButton.icon(onPressed:_toggle,icon:Icon(playing?Icons.pause:Icons.play_arrow),label:Text(playing?'إيقاف مؤقت':'استمع إلى الأذان')),const SizedBox(height:8),OutlinedButton.icon(onPressed:downloading?null:_download,icon:const Icon(Icons.download_for_offline),label:Text(downloading?'جارٍ التنزيل...':available?'إعادة تنزيل الأذان':'تنزيل الأذان للاستماع دون إنترنت')),if(status!=null)Padding(padding:const EdgeInsets.all(12),child:Text(status!,style:const TextStyle(color:forest))),const SizedBox(height:15),const Text('صاحب التسجيل: Adam-synagda · CC0 1.0 Universal Public Domain Dedication. المصدر: Wikimedia Commons.',textAlign:TextAlign.center,style:TextStyle(color:Colors.black45,fontSize:11,height:1.6))]))));}

class QiblaPage extends StatefulWidget{const QiblaPage({super.key});@override State<QiblaPage> createState()=>_QiblaPageState();}
class _QiblaPageState extends State<QiblaPage>{double lat=14.5425,lon=49.1242,heading=0;StreamSubscription<MagnetometerEvent>? sub;bool locating=false;String place='المكلا (إعداد افتراضي)';double get bearing=>Qibla.qibla(Coordinates(lat,lon));@override void initState(){super.initState();_sensor();_load();}void _sensor(){sub=magnetometerEvents.listen((e){final h=(math.atan2(-e.x,e.y)*180/math.pi+360)%360;if(mounted)setState(()=>heading=h);},onError:(_){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تعذر قراءة بوصلة الهاتف')));});}Future<void> _load()async{final p=await SharedPreferences.getInstance();if(!mounted)return;setState(() { lat = p.getDouble('lat') ?? lat; lon = p.getDouble('lon') ?? lon; place = p.getString('city') ?? place; });}Future<void> _locate()async{setState(()=>locating=true);try{if(!await Geolocator.isLocationServiceEnabled())throw Exception('فعّل الموقع');var p=await Geolocator.checkPermission();if(p==LocationPermission.denied)p=await Geolocator.requestPermission();if(p==LocationPermission.denied||p==LocationPermission.deniedForever)throw Exception('إذن الموقع غير متاح');final pos=await Geolocator.getCurrentPosition();final prefs=await SharedPreferences.getInstance();if(!mounted)return;await prefs.setDouble('lat',pos.latitude);await prefs.setDouble('lon',pos.longitude);await prefs.setString('city','موقعي الحالي');setState(() { lat = pos.latitude; lon = pos.longitude; place = 'موقعي الحالي'; });}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString())));}finally{if(mounted)setState(()=>locating=false);}}@override void dispose(){sub?.cancel();super.dispose();}@override Widget build(BuildContext context){final angle=(bearing-heading)*math.pi/180;return Scaffold(appBar:AppBar(title:const Text('اتجاه القبلة')),body:Center(child:Padding(padding:const EdgeInsets.all(20),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[Text(place,style:const TextStyle(color:Colors.black54)),const SizedBox(height:20),Container(width:280,height:280,decoration:BoxDecoration(shape:BoxShape.circle,color:mint,border:Border.all(color:forest,width:2),boxShadow:[BoxShadow(color:forest.withValues(alpha:.1),blurRadius:20)]),child:Stack(alignment:Alignment.center,children:[const Positioned(top:14,child:Text('N',style:TextStyle(color:deepGreen,fontWeight:FontWeight.bold))),const Positioned(bottom:14,child:Text('S',style:TextStyle(color:deepGreen,fontWeight:FontWeight.bold))),const Positioned(left:15,child:Text('W')),const Positioned(right:15,child:Text('E')),Transform.rotate(angle:angle,child:const Icon(Icons.navigation_rounded,size:105,color:forest)),const Positioned(bottom:72,child:Icon(Icons.mosque,color:gold,size:24))])),const SizedBox(height:20),Text('اتجاه القبلة ${bearing.toStringAsFixed(1)}° من الشمال',style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold,color:deepGreen)),const SizedBox(height:5),const Text('ضع الهاتف أفقياً وبعيداً عن المعادن، وحرّكه بشكل رقم 8 لمعايرة البوصلة.',textAlign:TextAlign.center,style:TextStyle(color:Colors.black54,height:1.5)),const SizedBox(height:15),FilledButton.icon(onPressed:locating?null:_locate,icon:const Icon(Icons.my_location),label:const Text('تحديث موقعي'))]))));}}

class HijriDate{final int year,month,day;const HijriDate(this.year,this.month,this.day);}
HijriDate toHijri(DateTime date){final gy=date.year,gm=date.month,gd=date.day;final a=(14-gm)~/12;final y=gy+4800-a;final m=gm+12*a-3;final jd=gd+(153*m+2)~/5+365*y+y~/4-y~/100+y~/400-32045;var l=jd-1948440+10632;final n=(l-1)~/10631;l=l-10631*n+354;final j=((10985-l)~/5316)*((50*l)~/17719)+(l~/5670)*((43*l)~/15238);l=l-((30-j)~/15)*((17719*j)~/50)-(j~/16)*((15238*j)~/43)+29;final month=(24*l)~/709;final day=l-(709*month)~/24;final year=30*n+j-30;return HijriDate(year,month,day);}
const hijriMonths=['','محرم','صفر','ربيع الأول','ربيع الآخر','جمادى الأولى','جمادى الآخرة','رجب','شعبان','رمضان','شوال','ذو القعدة','ذو الحجة'];
class HijriPage extends StatelessWidget{const HijriPage({super.key});@override Widget build(BuildContext context){final h=toHijri(DateTime.now());return Scaffold(appBar:AppBar(title:const Text('التقويم الهجري')),body:Center(child:Padding(padding:const EdgeInsets.all(22),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[const Icon(Icons.calendar_month,color:forest,size:55),const SizedBox(height:20),const Text('تاريخ اليوم الهجري التقريبي',style:TextStyle(color:Colors.black54)),Text('${h.day} ${hijriMonths[h.month]} ${h.year} هـ',style:const TextStyle(fontSize:27,fontWeight:FontWeight.w900,color:deepGreen)),const SizedBox(height:16),const Text('قد يختلف التاريخ الهجري يوماً حسب ثبوت رؤية الهلال والجهة الشرعية المحلية.',textAlign:TextAlign.center,style:TextStyle(color:Colors.black54,height:1.6))]))));}}

class SupportPage extends StatelessWidget{const SupportPage({super.key});Future<void> _copy(BuildContext context,String s)async{await Clipboard.setData(ClipboardData(text:s));if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تم النسخ')));}@override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('ادعم تطوير سكينة')),body:ListView(padding:const EdgeInsets.all(18),children:[Container(padding:const EdgeInsets.all(22),decoration:BoxDecoration(gradient:const LinearGradient(colors:[deepGreen,forest]),borderRadius:BorderRadius.circular(24)),child:const Column(children:[Icon(Icons.volunteer_activism,color:Colors.white,size:48),SizedBox(height:12),Text('ساهم في الخير',style:TextStyle(color:Colors.white,fontSize:25,fontWeight:FontWeight.w900)),SizedBox(height:8),Text('دعمك يساعدنا على مواصلة تطوير تطبيق سكينة وتحسين خدمات القرآن والأذكار ومواقيت الصلاة.',textAlign:TextAlign.center,style:TextStyle(color:Colors.white,height:1.7))])),const SizedBox(height:14),const SCard(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('لماذا تدعم سكينة؟',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold,color:deepGreen)),SizedBox(height:8),Text('• تطوير التطبيق وإضافة خدمات
