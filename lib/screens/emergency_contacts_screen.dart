import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/proximity_alert_service.dart';
import '../widgets/glass_container.dart';

/// Emergency contacts screen — backed by Firestore (not SharedPreferences).
/// Contacts have name + phone and are stored under users/{userId}/emergencyContacts.
/// Logic taken from the feature zip project; styled in the main app's dark glassmorphism theme.
class EmergencyContactsScreen extends StatefulWidget {
  const EmergencyContactsScreen({super.key});

  @override
  State<EmergencyContactsScreen> createState() =>
      _EmergencyContactsScreenState();
}

class _EmergencyContactsScreenState extends State<EmergencyContactsScreen> {
  List<EmergencyContact> _contacts = [];
  bool _isLoading = true;

  String? get _userId => ProximityAlertService().userId;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    try {
      if (_userId == null) return;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_userId)
          .get();
      if (doc.exists) {
        final data = doc.data();
        final list = data?['emergencyContacts'] as List<dynamic>?;
        if (list != null) {
          setState(() {
            _contacts = list
                .map((c) => EmergencyContact.fromMap(c as Map<String, dynamic>))
                .toList();
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading contacts: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveContacts() async {
    try {
      if (_userId == null) return;
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_userId)
          .update({'emergencyContacts': _contacts.map((c) => c.toMap()).toList()});

      // Refresh cached list in the service
      await ProximityAlertService().loadEmergencyContacts();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Emergency contacts saved!'), backgroundColor: Colors.green),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _showAddDialog() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text('Add Emergency Contact',
            style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          _dialogField(nameCtrl, 'Name', 'Mom, Dad, Friend...', TextInputType.name),
          const SizedBox(height: 12),
          _dialogField(phoneCtrl, 'Phone Number', '+8801XXXXXXXXX', TextInputType.phone),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CANCEL', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE53935)),
            onPressed: () {
              if (nameCtrl.text.trim().isNotEmpty && phoneCtrl.text.trim().isNotEmpty) {
                setState(() {
                  _contacts.add(EmergencyContact(name: nameCtrl.text.trim(), phone: phoneCtrl.text.trim()));
                });
                _saveContacts();
                Navigator.pop(ctx);
              }
            },
            child: const Text('ADD', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(int index) {
    final nameCtrl = TextEditingController(text: _contacts[index].name);
    final phoneCtrl = TextEditingController(text: _contacts[index].phone);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text('Edit Contact',
            style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          _dialogField(nameCtrl, 'Name', '', TextInputType.name),
          const SizedBox(height: 12),
          _dialogField(phoneCtrl, 'Phone Number', '', TextInputType.phone),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CANCEL', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            onPressed: () {
              if (nameCtrl.text.trim().isNotEmpty && phoneCtrl.text.trim().isNotEmpty) {
                setState(() {
                  _contacts[index] = EmergencyContact(
                      name: nameCtrl.text.trim(), phone: phoneCtrl.text.trim());
                });
                _saveContacts();
                Navigator.pop(ctx);
              }
            },
            child: const Text('SAVE', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Delete Contact', style: TextStyle(color: Colors.white)),
        content: Text('Delete ${_contacts[index].name}?',
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CANCEL', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              setState(() => _contacts.removeAt(index));
              _saveContacts();
              Navigator.pop(ctx);
            },
            child: const Text('DELETE', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _dialogField(TextEditingController ctrl, String label, String hint, TextInputType kb) {
    return TextField(
      controller: ctrl,
      keyboardType: kb,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Colors.white54),
        hintStyle: const TextStyle(color: Colors.white24),
        enabledBorder:
            const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
        focusedBorder:
            const UnderlineInputBorder(borderSide: BorderSide(color: Colors.blueAccent)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text('Emergency Contacts',
            style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0F172A), Color(0xFF1E1E1E), Color(0xFF2D1B2E)],
          ),
        ),
        child: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      GlassContainer(
                        padding: const EdgeInsets.all(16),
                        opacity: 0.1,
                        border: Border.all(color: Colors.white10),
                        child: const Row(children: [
                          Icon(Icons.warning, color: Colors.redAccent, size: 26),
                          SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              'These contacts receive an SMS with your GPS location '
                              'during a MAJOR ALERT. Max 5 contacts.',
                              style:
                                  TextStyle(fontSize: 12, color: Colors.white, height: 1.4),
                            ),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 20),
                      Expanded(
                        child: _contacts.isEmpty
                            ? const Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.contacts, size: 64, color: Colors.white24),
                                    SizedBox(height: 16),
                                    Text('No emergency contacts added',
                                        style: TextStyle(color: Colors.white54)),
                                    SizedBox(height: 8),
                                    Text('Tap + to add contacts',
                                        style: TextStyle(color: Colors.white30, fontSize: 12)),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                itemCount: _contacts.length,
                                itemBuilder: (context, index) {
                                  final c = _contacts[index];
                                  return GlassContainer(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    padding: const EdgeInsets.all(4),
                                    child: ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor: const Color(0xFFE53935),
                                        child: Text(c.name[0].toUpperCase(),
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold)),
                                      ),
                                      title: Text(c.name,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold)),
                                      subtitle: Text(c.phone,
                                          style: const TextStyle(
                                              color: Colors.white54, fontSize: 13)),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.edit,
                                                color: Colors.blueAccent, size: 20),
                                            onPressed: () => _showEditDialog(index),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.delete,
                                                color: Colors.redAccent, size: 20),
                                            onPressed: () => _showDeleteDialog(index),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
      floatingActionButton: _contacts.length < 5
          ? FloatingActionButton(
              backgroundColor: const Color(0xFFE53935),
              onPressed: _showAddDialog,
              child: const Icon(Icons.add, color: Colors.white),
            )
          : null,
    );
  }
}
