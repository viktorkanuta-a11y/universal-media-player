import 'package:flutter/material.dart';

import 'feedback_button.dart';

/// Главное окно RePlay по макету Qwen (пока без обработки).
class ReplayHome extends StatefulWidget {
  const ReplayHome({super.key});

  @override
  State<ReplayHome> createState() => _ReplayHomeState();
}

const Color _violet = Color(0xFF3B1F5C);
const Color _coral = Color(0xFFE8664A);
const Color _background = Color(0xFFF4F5F8);
const TextStyle _labelStyle = TextStyle(fontSize: 15, color: Colors.black87);

class _ReplayHomeState extends State<ReplayHome> {
  static const List<String> _sections = [
    'Увеличить',
    'Улучшить',
    'Видео',
    'Аудио',
  ];

  int _selected = 0;
  double _quality = 0.6;
  final TextEditingController _width = TextEditingController();
  final TextEditingController _height = TextEditingController();

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    super.dispose();
  }

  void _soon(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSidebar(),
          Expanded(child: _buildCenter()),
          _buildSettings(),
        ],
      ),
    );
  }

  // Левая панель с разделами
  Widget _buildSidebar() {
    return Container(
      width: 200,
      padding: const EdgeInsets.fromLTRB(16, 48, 16, 24),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_violet, Color(0xFF7A2E5C), Color(0xFFE07A5F)],
        ),
      ),
      child: Column(
        children: [
          const Text(
            'RePlay',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 40),
          for (int i = 0; i < _sections.length; i++) ...[
            _SectionButton(
              label: _sections[i],
              active: i == _selected,
              onTap: () => setState(() => _selected = i),
            ),
            const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }

  // Центр: зона для картинки
  Widget _buildCenter() {
    if (_selected != 0) {
      return Center(
        child: Text(
          'Раздел «${_sections[_selected]}» — скоро',
          style: const TextStyle(fontSize: 22, color: Colors.black54),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _soon('Выбор картинки подключим на следующих шагах'),
            child: CustomPaint(
              painter: _DashedBorderPainter(color: _coral),
              child: const SizedBox(
                width: 520,
                height: 340,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Перетащи картинку сюда',
                      style: TextStyle(fontSize: 22, color: Colors.black87),
                    ),
                    SizedBox(height: 16),
                    Icon(Icons.upload_outlined, size: 48, color: Colors.black87),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Правая панель настроек
  Widget _buildSettings() {
    return Container(
      width: 280,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Размер печати, м', style: _labelStyle),
          const SizedBox(height: 10),
          _field(_width, 'Ширина'),
          const SizedBox(height: 12),
          _field(_height, 'Высота'),
          const SizedBox(height: 28),
          const Text('Качество', style: _labelStyle),
          Slider(
            value: _quality,
            activeColor: _coral,
            onChanged: (value) => setState(() => _quality = value),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _coral,
                shape: const StadiumBorder(),
              ),
              onPressed: () =>
                  _soon('Движок увеличения подключим на следующих шагах'),
              child: const Text('Запустить', style: TextStyle(fontSize: 18)),
            ),
          ),
          const Spacer(),
          const FittedBox(
            fit: BoxFit.scaleDown,
            child: DesignFeedbackButton(),
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController controller, String hint) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _coral),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _coral, width: 2),
        ),
      ),
    );
  }
}

class _SectionButton extends StatelessWidget {
  const _SectionButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Container(
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? const Color(0x38FFFFFF) : const Color(0x1AFFFFFF),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: active ? _coral : Colors.transparent,
              width: 2,
            ),
            boxShadow: active
                ? const [BoxShadow(color: Color(0x88E8664A), blurRadius: 16)]
                : null,
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// Пунктирная рамка вокруг зоны для картинки.
class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(16)),
      );
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + 10), paint);
        distance += 18;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color;
}
