import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Временная кнопка: Марина описывает, как видит дизайн.
/// Пожелание уходит в раздел Issues репозитория на GitHub.
class DesignFeedbackButton extends StatelessWidget {
  const DesignFeedbackButton({super.key});

  static final Uri _formUrl = Uri.https(
    'github.com',
    '/viktorkanuta-a11y/universal-media-player/issues/new',
    {
      'title': 'Пожелания Марины по дизайну',
      'body': '### Что нравится\n\n\n'
          '### Что поменять\n\n\n'
          '### Цвета и шрифты\n\n\n'
          '### Картинки\n'
          '(перетащи картинки сюда)\n',
    },
  );

  Future<void> _openForm(BuildContext context) async {
    bool ok = false;
    try {
      ok = await launchUrl(_formUrl, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не получилось открыть браузер')),
      );
    }
  }

  void _showHint(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Ты дизайнер — опиши, как видишь'),
        content: const Text(
          '1. Нажми «Открыть форму» — откроется браузер.\n'
          '2. Если попросит войти — войди в свой GitHub.\n'
          '3. Напиши ответы под вопросами, картинки перетащи в поле текста.\n'
          '4. Нажми зелёную кнопку Create (или Submit new issue).',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Потом'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _openForm(context);
            },
            child: const Text('Открыть форму'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: () => _showHint(context),
      icon: const Icon(Icons.brush),
      label: const Text('Ты дизайнер — опиши, как видишь'),
    );
  }
}
