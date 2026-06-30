# Sweep — Apple HIG Uyum Notları

Bu dosya, uygulamanın Apple Human Interface Guidelines'a (macOS) hangi
kararlarla uyduğunu belgeler. Kaynaklar aşağıda.

## Menü çubuğu (Menu Bar Extras)
- İkon **template** (tek renk, alfa) `NSImage.isTemplate = true` → menü çubuğu
  rengine otomatik uyum (açık/koyu, vurgu). SF Symbol: `sparkles`.
- Uygulama **accessory** (LSUIElement): Dock ikonu yok, ana pencere yok.
  `setActivationPolicy(.accessory)`.
- İçerik **transient popover** içinde; dışarı tıklayınca kapanır.

## Tipografi
- Tamamen sistem metin stilleri: `.headline`, `.callout`, `.footnote`.
- Büyük "geri kazanılabilir" sayısı: `.system(size:36, weight:.semibold, design:.rounded)` + `monospacedDigit()` → rakamlar zıplamaz.
- `contentTransition(.numericText())` → sayı değişiminde yumuşak geçiş.

## Renk & Materyal
- Sadece **semantik** renkler (`.green`, `.orange`, `.accentColor`, `.secondary`)
  → açık/koyu moda otomatik uyum.
- Panel arka planı **`.regularMaterial`** (vibrancy) → HIG materyal katmanı.
- Güvenlik rengi: yeşil = güvenli, turuncu = dikkat. İkon kutusu rengin %15 opaklığı.

## Düzen & Dokunma hedefi
- 4/8/12/16/20 pt'lik tutarlı boşluk ölçeği (`DS`).
- Satırın tamamı tek dokunma hedefi (`contentShape(Rectangle())`).
- Köşe yarıçapları kontrol yarıçaplarıyla eşmerkezli (kart 12, ikon 8).

## Butonlar
- Birincil eylem: `.borderedProminent`, `.controlSize(.large)`, tam genişlik.
- Yıkıcı işlem (kalıcı silme) **onay diyaloğu** ardında (`confirmationDialog`,
  `role: .destructive`) — HIG'in "geri alınamaz işlemleri onayla" kuralı.
- İkincil/araç butonları `.borderless`.

## Pass 2 — Liquid Glass (macOS 26 / Tahoe)
Sonraki adımda eklenecek; doğrulanmış API yüzeyi:
- `.glassEffect(_:in:)` — varsayılan `.regular` + `Capsule`.
- `GlassEffectContainer { }` — birden çok cam yüzeyi tek örnekleme bölgesinde
  birleştirir; **performans için birden fazla `.glassEffect` kullanılınca şart.**
- Buton: `.buttonStyle(.glass)` / `.glassProminent` (doğrudan `.glassEffect`
  yerine buton stili önerilir).
- Kural: **kontroller fonksiyonel katmanda, içerik içerik katmanında.**
  Cam, başka camı örnekleyemez → container ile birleştir.

## Kaynaklar
- https://developer.apple.com/design/human-interface-guidelines/the-menu-bar
- https://developer.apple.com/design/human-interface-guidelines/materials
- https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)
- https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views
- https://github.com/conorluddy/LiquidGlassReference
