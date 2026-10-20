import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../monitor/monitor_page.dart';
import '../settings/settings_page.dart';
import 'add_printer_sheet.dart';

/// Home shell: the single monitoring screen (FR-1) plus the settings
/// entry. Everything else - printer list, dashboard, cameras - lives in
/// [MonitorPage].
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: DeckColors.bg,
        title: const Text('BambuDeck',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      body: MonitorPage(
        onAddPrinter: () => _openAddSheet(context),
      ),
    );
  }

  void _openAddSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: DeckColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => const AddPrinterSheet(),
    );
  }
}
