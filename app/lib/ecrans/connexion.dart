import 'package:flutter/material.dart';
import '../i18n.dart';

import '../api.dart';
import '../theme.dart';

/// Inscription et connexion.
///
/// Pas d'adresse mail : un pseudo et un mot de passe suffisent. On le dit
/// clairement à l'écran, parce que la contrepartie compte — un mot de passe
/// oublié ne se récupère pas.
class EcranConnexion extends StatefulWidget {
  const EcranConnexion({super.key, required this.surConnexion});
  final VoidCallback surConnexion;

  @override
  State<EcranConnexion> createState() => _EcranConnexionState();
}

class _EcranConnexionState extends State<EcranConnexion> {
  final _pseudo = TextEditingController();
  final _mdp = TextEditingController();
  final _adresse = TextEditingController();

  bool _inscription = false;
  bool _occupe = false;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _adresse.text = Api.instance.adresse;
  }

  @override
  void dispose() {
    _pseudo.dispose();
    _mdp.dispose();
    _adresse.dispose();
    super.dispose();
  }

  Future<void> _valide() async {
    setState(() {
      _occupe = true;
      _erreur = null;
    });
    try {
      await Api.instance.changeAdresse(_adresse.text);
      if (_inscription) {
        await Api.instance.inscription(_pseudo.text, _mdp.text);
      } else {
        await Api.instance.connexion(_pseudo.text, _mdp.text);
      }
      widget.surConnexion();
    } on ErreurApi catch (e) {
      setState(() => _erreur = e.message);
    } catch (e) {
      setState(() => _erreur = '$e');
    } finally {
      if (mounted) setState(() => _occupe = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.pets, size: 56, color: Palette.accent),
                  const SizedBox(height: 16),
                  const Text('Biodex',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text(
                    T('Photographie les animaux que tu croises,\\nremplis ton dex.'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Palette.texteDoux, height: 1.4),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _pseudo,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      hintText: T('Pseudo'),
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _mdp,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _occupe ? null : _valide(),
                    decoration: InputDecoration(
                      hintText: T('Mot de passe'),
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _adresse,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      labelText: T('Adresse du serveur'),
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                  ),
                  if (_erreur != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Palette.alerte.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(children: [
                        Icon(Icons.error_outline,
                            color: Palette.alerte, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(_erreur!,
                              style: TextStyle(
                                  color: Palette.alerte, fontSize: 13)),
                        ),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _occupe ? null : _valide,
                    child: _occupe
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text(_inscription ? 'Créer mon compte' : 'Me connecter'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _occupe
                        ? null
                        : () => setState(() {
                              _inscription = !_inscription;
                              _erreur = null;
                            }),
                    child: Text(_inscription
                        ? 'J\'ai déjà un compte'
                        : 'Créer un compte'),
                  ),
                  if (_inscription)
                    Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        T('Aucune adresse mail n\'est demandée. En échange, un mot de passe perdu ne peut pas être récupéré.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Palette.texteDoux, fontSize: 12, height: 1.4),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
