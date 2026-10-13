import 'package:flutter/material.dart';
import '../i18n.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../theme.dart';

/// Un timbre de carte montrant où une photo a été prise.
///
/// Il répond à une question qu'un couple de coordonnées ne résout pas :
/// « 48.8566, 2.3522 » ne dit rien à personne, alors qu'un bout de plan dit
/// tout de suite si l'on est au bon endroit ou à trois départements de là.
/// C'est là que se repèrent les erreurs — la photo de vacances envoyée depuis
/// le canapé, le point tombé au milieu de la Manche.
///
/// Volontairement inerte : ni glissement, ni zoom, ni rotation. Un appui ouvre
/// l'écran qui sait vraiment situer une photo. Sur une carte de résultat qui
/// défile, une carte manipulable happerait le doigt à chaque passage.
class ApercuLieu extends StatelessWidget {
  const ApercuLieu({
    super.key,
    required this.lat,
    required this.lon,
    this.hauteur = 116,
    this.approximatif = false,
    this.onTap,
  });

  final double lat;
  final double lon;
  final double hauteur;

  /// Vrai quand le point n'est qu'une supposition — le lieu de l'envoi plutôt
  /// que celui de la prise de vue. Le marqueur le dit, sans quoi l'aperçu
  /// donnerait à une approximation l'aplomb d'une mesure.
  final bool approximatif;

  final VoidCallback? onTap;

  /// Le zoom de l'aperçu.
  ///
  /// Assez serré pour reconnaître le quartier, assez large pour ne pas donner
  /// l'illusion d'une précision au mètre : les positions « par défaut » sont
  /// souvent fausses de plusieurs kilomètres, et un plan de rue laisserait
  /// croire qu'on tient l'adresse exacte.
  static const _zoom = 13.0;
  static const _zoomApproximatif = 10.0;

  @override
  Widget build(BuildContext context) {
    final couleur = approximatif ? const Color(0xFFB08A00) : Palette.accent;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: hauteur,
          width: double.infinity,
          child: Stack(children: [
            FlutterMap(
              options: MapOptions(
                initialCenter: LatLng(lat, lon),
                initialZoom: approximatif ? _zoomApproximatif : _zoom,
                // Toutes les interactions coupées : l'aperçu est une image,
                // pas une carte.
                interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.none),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'fr.biodex.app',
                  maxNativeZoom: 19,
                ),
                MarkerLayer(markers: [
                  Marker(
                    point: LatLng(lat, lon),
                    width: 30,
                    height: 30,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: couleur,
                        border: Border.all(color: Colors.white, width: 2.5),
                        boxShadow: const [
                          BoxShadow(color: Colors.black26, blurRadius: 4),
                        ],
                      ),
                      child: Icon(
                          approximatif ? Icons.question_mark : Icons.photo_camera,
                          size: 14,
                          color: Colors.white),
                    ),
                  ),
                ]),
              ],
            ),
            // OpenStreetMap demande son attribution, y compris sur une
            // vignette. Discrète, mais présente.
            Positioned(
              right: 0,
              bottom: 0,
              child: ColoredBox(
                color: Colors.white70,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  child: Text(T('© OpenStreetMap'),
                      style: TextStyle(
                          fontSize: 8.5, color: Colors.black.withValues(alpha: .7))),
                ),
              ),
            ),
            if (onTap != null)
              Positioned(
                left: 6,
                top: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .45),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    child: Text(T('Corriger'),
                        style: TextStyle(color: Colors.white, fontSize: 10.5)),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
