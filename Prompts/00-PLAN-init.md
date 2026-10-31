# Automatka — Implementační plán (POC → MVP → hodinky)

Appka pro rodiče, jejichž děti už jezdí na kroužky samy (MHD, pěšky), ale rodič
chce vědět, že dítě dorazilo a odešlo. Postaveno na PMTrackeru
(`lioilsources/PMTracker`): stejný princip *„přihlásím se jen tehdy, když GPS
odpovídá místu"*, stejný stack, stejná ochrana soukromí (poloha se ověří a
zahodí). Vstup pro pokračování v terminálu (claude-code).

---

## 1. Cíl a persony

- **Rodič** (hlavní uživatel, platí). Zakládá rodinu, děti, místa a kroužky.
  Chce dostat push *„Anička je na keramice (16:02)"* a *„Anička se do 16:15
  nepřihlásila"*. Nechce mapu s tečkou, která se hýbe — to je důvod, proč
  nepoužívá Life360.
- **Dítě** (6–14 let). Má telefon **nebo jen Apple Watch**. Jediná úloha: na
  místě zmáčknout *„Jsem tu"*, při odchodu *„Odcházím"*, doma *„Jsem doma"*.
  Žádné přihlašování e-mailem, žádné nastavování.
- **Druhý rodič / babička** (sekundární). Stejný pohled jako rodič, méně práv
  (nemůže mazat rodinu).

**Hodnotová smyčka MVP:** *rodič založí kroužek s místem a časem → spáruje
dítěti zařízení → dítě na místě zmáčkne „Jsem tu" → server ověří polohu →
rodič dostane push. Když se dítě nepřihlásí do tolerance, rodič dostane
upozornění.*

**Co Automatku odlišuje (a co se nesmí rozmělnit):** žádné průběžné sledování.
Poloha se odešle jen při akci dítěte, server rozhodne „na místě / ne" a
souřadnice zahodí. Rodič nikdy neuvidí trasu. To je marketingová věta i
GDPR příběh.

---

## 2. Co se bere z PMTrackeru a co je nové

| PMTracker | Automatka | Poznámka |
|---|---|---|
| `companies` | `families` | 1 rodina = tenant, `family_id` všude |
| role `admin/manager/member` | `parent/guardian/child` | admin odpadá, rodič-zakladatel je `owner` flag |
| `jobs` (místo + geofence) | `places` (domov, škola, kroužek, babička) | místo bez rozvrhu |
| — | `activities` + `activity_schedule` | **nové**: kroužek = místo + opakovaný čas |
| `job_assignments` | `activity_children` | M:N dítě ↔ kroužek |
| `time_entries` start/stop | `checkins` arrive/leave/home | write-only přes RPC, coords zahozeny |
| `within_geofence` + override | **mimo geofence = odmítnuto** | viz rozhodnutí 3.1 |
| `audit_log` | `alerts` | nepřihlášení, SOS, pozdní příchod domů |
| `get_member_utilization` | denní timeline dítěte | místo hodin události |
| e-mail + heslo | **párování zařízení kódem** | dítě nemá e-mail |
| push ve Fázi 2 | **push v MVP** | bez pushe appka nemá smysl |
| — | **watchOS appka (nativní Swift)** | Flutter watchOS neumí |

**Převzít beze změny (zkopírovat, ne forkovat — doména je jiná):**
- Skeleton `app/lib/core/{router,theme,supabase_client}.dart`,
  `shared/shell/app_shell.dart`, `shared/widgets/error_view.dart`, Riverpod +
  codegen (`@riverpod`, `build_runner`), GoRouter redirect podle auth stavu.
- Vzor migrace `supabase/migrations/20260618000000_init.sql`: helpery
  `get_my_*()`, SECURITY DEFINER RPC, `ST_DWithin`, RLS `WITH CHECK (FALSE)` na
  write-only tabulkách, `update_updated_at()` trigger, `pg_cron` job.
- `scripts/{run.sh,build-apk.sh,create-test-users.mjs}`, `.env.example`,
  `seed.sql` hledající uživatele podle e-mailu (ne ručně kopírované UUID).
- `.github/workflows/{ci,release-android,release-ios}.yml` (Firebase App
  Distribution skupina, TestFlight upload, verze z `pubspec` + run number).
- Stránka na olin.now (`apps/automatka/meta.md` + sekce pro beta testery).

**Poučení z PMTrackeru, která se mají aplikovat hned:**
- `SUPABASE_PUBLISHABLE_KEY` (ne `ANON_KEY`) všude od prvního commitu, v CI
  stejný název secretu.
- iOS deployment target **15.0** v `Podfile`, `project.pbxproj` i
  `post_install` — 13.0 Xcode 26 odmítá.
- Flutter 3.47+ (riverpod_generator 4 → Dart 3.12); CI pinovat stejnou verzi.
- Tagovat releasy **na `main`**, ne na vedlejší větvi (beta PMTrackeru visela
  měsíc na `testing-setup`).
- Release notes pro testery psát rovnou do GitHub Release (instalace APK,
  testovací účty, co vyzkoušet) — olin.now je z nich přebírá.

---

## 3. Architektonická rozhodnutí

**Zamčeno (přenáší se z PMTrackeru):**
- Zápis do `checkins` a `alerts` výhradně přes SECURITY DEFINER RPC. Klient
  nikdy nerozhoduje o `within_geofence`.
- Syrové souřadnice se nikam neukládají. Server ověří `ST_DWithin(place.location,
  point, radius_m)`, uloží boolean a souřadnice zahodí. Ani v `alerts`, ani v
  logu Edge Function.
- `family_id` na každé tabulce, `get_my_family_id()` z `profiles`. Multi-tenant
  od začátku — tohle je produkt na prodej, ne appka pro jednu firmu.
- Oprávnění vynucuje RLS, ne klient (dětská appka je nejsnáze „upravitelný
  klient" ze všech).

**3.1 Mimo geofence = odmítnuto, ne override.** PMTracker má override s důvodem
(dělník pracuje mimo stavbu). U dítěte override nedává smysl — buď tam je, nebo
není. RPC `check_in` při nesouhlasu polohy vrátí chybu, appka ukáže *„Ještě
nejsi na místě"* a nic se neuloží. **Otevřená výjimka:** GPS v tělocvičnách a
suterénech (keramika v DDM, florbal v hale) je mizerná. Navrhovaná pojistka:
tlačítko *„Nejde mi zjistit polohu"* → check-in se uloží s
`verified = false` a rodič ho vidí šedě jako *„nepotvrzeno polohou"*. Rozhodnout
před MVP (sekce 4). Bez téhle pojistky appka v hale selže a dítě ji přestane
používat.

**3.2 Dítě = anonymní Supabase uživatel spárovaný kódem.** Rodič v appce vytvoří
dítě → RPC `create_pairing_code(child_id)` vrátí 6místný kód (platnost 15 min).
Dětské zařízení se přihlásí `signInAnonymously()` a zavolá
`pair_device(code, platform, push_token)` → server naváže `auth.uid()` na
`profiles` dítěte a zapíše `devices` řádek. Jeden dítě-profil může mít víc
zařízení (telefon + hodinky). Odpárování = rodič smaže zařízení → RPC zruší
session. Child session nikdy nedostane e-mail ani heslo; ztráta zařízení =
nový kód.

**3.3 Rozvrh je zdrojem pravdy pro upozornění.** `activity_schedule` (den v
týdnu, od–do, platnost od–do) + `activity_exceptions` (datum: zrušeno /
posunuto). `pg_cron` každou minutu projde dnešní očekávané události
(`expected_events` view) a kde chybí `checkin` do tolerance, založí `alert`.
Trigger na `alerts` → `pg_net` → Edge Function `push` → FCM / APNs. Bez
rozvrhu nejde říct „nepřihlásila se", jen „přihlásila se" — a to rodiči nestačí.

**3.4 Hodinky jsou nativní watchOS target, ne Flutter.** Flutter watchOS
nepodporuje. Watch appka je SwiftUI target v `app/ios/` (**independent watchOS
app**, aby šla instalovat na hodinky bez iPhonu — Family Setup). Sdílí jen
backend kontrakt: tři RPC (`pair_device`, `check_in`, `my_today`) přes
PostgREST — holé `URLSession` POSTy nebo `supabase-swift`. CoreLocation na
hodinkách funguje (GPS mají všechny od Series 2). Push přes APNs přímo na
watchOS. Komplikace / Smart Stack: *„Keramika 16:00 · Jsem tu"*.

**3.5 Žádné background location v MVP.** Oprávnění jen *When In Use*. Appka
polohu čte výhradně po stisku tlačítka. To drží GDPR příběh, baterii i
schvalování v App Store / Play. OS-level geofencing (automatický check-in při
vstupu do oblasti) je až Fáze 3 a vyžaduje *Always* — samostatné rozhodnutí.

**Rezervovat (levné teď):**
- `places.kind = home` — domov je místo jako každé jiné; „Jsem doma" je
  `check_in(home_place, 'home')`. Umožní později „pozdní příchod domů".
- `activities.organizer_id` nullable — pro budoucí B2B (kroužek jako tenant
  vidí docházku svých dětí = PMTracker roster naruby).
- `checkins.device_id` — aby šlo říct „z hodinek" vs. „z telefonu".

---

## 4. Otázky k rozhodnutí před MVP

**Door-closery:**
1. **Nepotvrzený check-in (3.1):** povolit *„Nejde mi zjistit polohu"* s
   viditelným flagem, nebo tvrdě odmítat? *(Doporučení: povolit a flagovat.)*
2. **Hodinky bez iPhonu:** cílíme na Apple Watch přes **Family Setup** (hodinky
   s cellular spravované z rodičova iPhonu). Ověřit, že Family Setup a eSIM
   pro hodinky jsou dostupné u českých operátorů — pokud ne, dítě s hodinkami
   potřebuje aspoň Wi-Fi v místě kroužku a check-in dorazí se zpožděním.
3. **Store kategorie:** appka je pro rodiče (účet zakládá dospělý), ale dětská
   část běží na dětském zařízení. Apple *Kids Category* a Google *Designed for
   Families* mají tvrdé podmínky (žádná analytika třetích stran, žádné reklamy,
   žádné externí odkazy). Rozhodnout, zda do nich jít (viditelnost) nebo se jim
   vyhnout (jednodušší review). *(Doporučení pro MVP: nejít, ale dětskou část
   stavět tak, aby podmínky splňovala — bez analytiky, bez odkazů.)*

**Pro MVP tak jako tak:**
- Tolerance příchodu (±15 min?) a odchodu; co když kroužek skončí dřív.
- Kdo dostává push: oba rodiče vždy, nebo per kroužek „kdo dnes vyzvedává".
- SOS: jen push rodičům, nebo i volání? *(MVP: push + tlačítko „Zavolat".)*
- Má dítě vidět historii (gamifikace „14 dní v řadě"), nebo jen dnešek?
- Jazyk: jen čeština, nebo od začátku i18n (olin.now umí `i18n/`).
- Cena: freemium (1 dítě zdarma, rodina placeně)? Rozhodnout až po betě, ale
  `families.plan` sloupec přidat hned.

**Do MVP NEpatří (proti scope creepu):** chat mezi rodičem a dítětem, mapa,
trasa cesty, ETA, sdílení s kroužkem (B2B), Wear OS, automatický check-in,
import rozvrhu ze školy, víc rodin na jedno dítě (rozvedení rodiče — Fáze 3).

---

## 5. Datový model

```
families           id, name, plan, created_at
profiles           id (= auth.users.id), family_id, role parent|guardian|child,
                   display_name, color, birth_year (jen child), is_owner
devices            id, profile_id, platform ios|android|watchos|wearos,
                   push_token, model, paired_at, last_seen_at, revoked_at
pairing_codes      id, child_id, code, expires_at, used_at, used_by_device
places             id, family_id, name, kind home|school|activity|other,
                   address, location geography(Point), radius_m (default 150)
activities         id, family_id, place_id, name, color, organizer_id null,
                   active bool
activity_schedule  id, activity_id, weekday 1–7, starts time, ends time,
                   valid_from date, valid_to date null
activity_exceptions id, activity_id, date, kind cancelled|moved,
                   starts time null, ends time null, note
activity_children  activity_id, child_id, notify_parent_ids uuid[] null
checkins           id, family_id, child_id, device_id, place_id,
                   activity_id null, kind arrive|leave|home,
                   client_ts, server_ts, verified bool, delivered_late bool
alerts             id, family_id, child_id, activity_id null,
                   kind missed_arrival|missed_departure|late_home|sos|unverified,
                   created_at, acknowledged_by null, acknowledged_at null
```

**RPC (SECURITY DEFINER):**
- `create_pairing_code(child_id)` → code — jen parent/guardian téže rodiny.
- `pair_device(code, platform, push_token, model)` — volá anonymní session;
  naváže `profiles` + `devices`, kód spálí.
- `check_in(place_id, kind, lat, lng, client_ts, unverifiable bool)` — ověří
  geofence, souřadnice zahodí, spáruje s dnešní `activity` podle rozvrhu,
  vrátí řádek. Mimo geofence a bez `unverifiable` → `RAISE EXCEPTION`.
- `my_today()` — pro dítě/hodinky: dnešní kroužky s místem, časem a stavem
  (nepřihlášen / na místě od / odešel). Jediný dotaz, který hodinky potřebují.
- `family_today()` — pro rodiče: totéž pro všechny děti + nevyřízené alerty.
- `acknowledge_alert(id)`, `revoke_device(id)`, `send_sos()`.
- `raise_missed_alerts()` — volá `pg_cron` každou minutu.

**RLS:** parent/guardian čte vše v `family_id`; child čte jen své `profiles`,
své `activity_children` → `activities` → `places`, své `checkins`. Child nikdy
nečte jiné děti ani `alerts`. `checkins`, `alerts`, `devices`,
`pairing_codes`: `INSERT/UPDATE/DELETE WITH CHECK (FALSE)` — jen RPC.

---

## 6. Push pipeline (nové oproti PMTrackeru, kritické)

```
pg_cron (1 min) → raise_missed_alerts() → INSERT alerts
                                              ↓ trigger
                                     pg_net POST → Edge Function `push`
                                              ↓
                              devices.push_token rodičů → FCM (Android)
                                                        → APNs (iOS + watchOS)
check_in RPC → INSERT checkins → stejný trigger → push „Anička je na keramice"
```

- Edge Function v Deno, APNs přes token-based auth (`.p8`), FCM přes
  HTTP v1. Tokeny z `devices`, neplatné tokeny → `revoked_at`.
- Idempotence: `alerts` má unique `(child_id, activity_id, date, kind)` —
  cron nesmí poslat „nepřihlásila se" dvakrát.
- Nepřihlášení se zruší, když check-in dorazí se zpožděním (offline hodinky):
  alert se označí `resolved`, rodič dostane *„Anička se přihlásila (se
  zpožděním, 16:20)"*.

---

## 7. Repo struktura

```
Automatka/
├── supabase/
│   ├── migrations/      # schéma, RLS, RPC, pg_cron, pg_net trigger
│   ├── functions/push/  # Edge Function: APNs + FCM
│   └── seed.sql         # rodina Novákovi (viz 8.3)
├── app/                 # Flutter (rodič + dítě v jedné appce, role z profilu)
│   ├── lib/core/        # router, theme, supabase_client (z PMTrackeru)
│   ├── lib/features/    # auth+pairing, today (dítě), family (rodič),
│   │                    # places, activities, children, alerts, settings
│   ├── lib/shared/
│   └── ios/
│       └── AutomatkaWatch/   # SwiftUI independent watchOS app (Fáze 2)
├── scripts/             # run.sh, build-apk.sh, create-test-users.mjs
├── docs/{PLAN.md,DECISIONS.md}
└── Prompts/00-PLAN-init.md   # tento dokument
```

Jedna Flutter appka pro obě role: po přihlášení/spárování router přesměruje
podle `profiles.role` — dítě vidí jen *Dnes*, rodič má shell se záložkami
*Dnes · Děti · Kroužky · Místa · Upozornění*. Dvě appky ve storu by
zdvojnásobily review a distribuci; dětský režim musí být tak jednoduchý, že
záložky nepotřebuje.

---

## 8. Fáze 0 — POC (de-risking)

Rizika, která PMTracker neřešil, a proto se musí ověřit dřív než UI:

1. **Párování:** `signInAnonymously` + `pair_device` → child session vidí jen
   své věci (RLS test z PMTrackeru přepsaný na rodinu).
2. **Push end-to-end:** `check_in` → trigger → `pg_net` → Edge Function → push
   dorazí na iPhone i Android do 5 s. Včetně cron alertu „nepřihlásila se".
3. **Hodinky:** throwaway SwiftUI watch app — CoreLocation fix, POST
   `rpc/check_in` s anonymním JWT, zobrazit výsledek. Ověřit na reálných
   hodinkách bez iPhonu v dosahu (Wi-Fi / cellular). Tohle rozhodne, zda je
   Fáze 2 reálná.
4. **GPS v hale:** změřit přesnost v 3 reálných místech kroužků (DDM, hala,
   ZUŠ v suterénu). Nastavit default `radius_m` podle toho (150? 250?).
5. **Offline check-in:** letadlový režim → „Jsem tu" → online → dorazí
   s `delivered_late`, alert se vyřeší.

**8.3 Seed:** rodina *Novákovi*: rodiče `jana@automatka.test` /
`petr@automatka.test`, babička `babi@automatka.test` (guardian), děti
*Anička* (9) a *Kuba* (12). Místa: domov (reálná adresa v Praze), ZŠ, keramika
(DDM), florbal (hala), babička. Rozvrh: keramika út 16:00–17:30 (Anička),
florbal po+čt 17:00–18:30 (Kuba). Jeden předgenerovaný párovací kód pro každé
dítě (seed ho vypíše). `create-test-users.mjs` z PMTrackeru stačí přejmenovat.

**Hotovo když:** všech 5 bodů prošlo na reálných zařízeních a výsledky jsou
v `docs/DECISIONS.md` (hlavně naměřená přesnost GPS a verdikt k hodinkám).

---

## 9. Fáze 1 — MVP (telefon rodiče + telefon dítěte)

**Backend:** kompletní migrace (sekce 5), `expected_events` view, cron,
Edge Function `push`, seed.

**Dítě (jedna obrazovka, 90 % užití):**
1. *Dnes*: karta nejbližšího kroužku (název, místo, čas) + obří tlačítko
   **Jsem tu** → po ověření zelené *„Jsi na keramice ✓ 16:02"* a tlačítko se
   změní na **Odcházím**. Pod tím **Jsem doma** (vždy) a **SOS** (drž 2 s).
2. Mimo geofence: *„Ještě nejsi na místě"* + (dle rozhodnutí 4.1) *„Nejde mi
   zjistit polohu"*.
3. Stav sítě: offline → „odešle se, až bude signál", nic víc.
4. Párování: první spuštění = *„Zadej kód od rodiče"*, hotovo.

**Rodič:**
5. *Dnes*: děti jako karty — stav (čeká / na místě od / odešel / doma), dnešní
   plán, nevyřízené alerty nahoře. Pull-to-refresh + Realtime.
6. *Děti*: přidat dítě, párovací kód (QR + číslo), zařízení, odpárovat.
7. *Místa*: CRUD s mapou pro umístění bodu a poloměru (Flutter `flutter_map`,
   bez Google klíče). Adresa → souřadnice přes geocoding.
8. *Kroužky*: CRUD, místo, děti, rozvrh (dny + čas + platnost), výjimky
   („dnes odpadá"), tolerance.
9. *Upozornění*: seznam, potvrdit, nastavení kdo dostává co.
10. Pozvat druhého rodiče / babičku (e-mail invite, role guardian).

**Cross-cutting:**
11. Auth rodiče: e-mail + heslo + magic link (Supabase), onboarding = založení
    rodiny.
12. Push oprávnění, lokalizace oprávnění s textem *„Polohu použijeme jen ve
    chvíli, kdy dítě zmáčkne tlačítko"*.
13. Téma: dětský režim velké prvky, vysoký kontrast; rodičovský režim z
    PMTracker tématu.
14. Store buildy + Firebase App Distribution + TestFlight; stránka na olin.now
    se sekcí pro beta testery (hotový vzor v `apps/pmtracker/meta.md`).

**Hotovo když:** reálná rodina (2 rodiče, 1 dítě) projede týden: dítě se
přihlásí na 3 kroužcích, rodič dostane každý push do 10 s, jedno záměrné
nepřihlášení vyvolá alert, nikde v DB není souřadnice.

---

## 10. Fáze 2 — Apple Watch

- Independent watchOS app (SwiftUI) v `app/ios/AutomatkaWatch/`: párování
  kódem, *Dnes* z `my_today()`, tlačítka Jsem tu / Odcházím / Jsem doma / SOS,
  haptika při potvrzení.
- Komplikace + Smart Stack widget s nejbližším kroužkem; lokální notifikace
  „za 10 min keramika" (z rozvrhu, offline).
- APNs push na hodinky (potvrzení rodiče: „Mamka ví").
- Offline fronta v `UserDefaults`/SwiftData, odeslání při připojení.
- Distribuce: TestFlight umí watchOS; ověřit instalaci na Family Setup hodinky
  bez iPhonu (riziko — možná jen přes App Store).
- CI: `release-ios.yml` staví i watch target (stejný archiv, `xcodebuild`
  scheme s watch app).

**Hotovo když:** dítě s hodinkami bez telefonu absolvuje kroužek a rodič
dostane oba pushe.

---

## 11. Fáze 3 — pohodlí a růst

- **Automatický check-in** přes OS geofencing (iOS region monitoring, Android
  Geofencing API): OS probudí appku při vstupu, appka udělá jeden GPS fix a
  zavolá `check_in`. Vyžaduje *Always* oprávnění → samostatný opt-in a nový
  GDPR text. Souřadnice pořád nikam.
- **Wear OS** (Flutter na Wear OS jde, ale UI je nutné přepsat pro kulatý
  displej; nebo Compose). Až bude poptávka.
- **Cesta**: čas mezi „Odcházím" ze školy a „Jsem tu" na kroužku → „obvykle
  25 min, dnes 40" bez jakékoli polohy mezi tím.
- **Více rodin na jedno dítě** (rozvedení rodiče), sdílení s babičkou jen
  pro vybrané kroužky.
- **Import rozvrhu** (Bakaláři / Škola OnLine API, ICS).
- **Gamifikace pro dítě**: série, odznaky — opatrně, nesmí tlačit k podvodu.
- **Anti-cheat**: detekce mock-location (Android `isMock`, iOS jailbreak
  heuristiky) → check-in označen `suspicious`.

---

## 12. Fáze 4 — B2B a monetizace

- **Kroužek jako tenant** (`activities.organizer_id`): DDM / sportovní klub
  vidí docházku dětí, jejichž rodiče to povolili. To je PMTracker roster
  z druhé strany — stejné RPC, jiná RLS. Prodej organizátorům kroužků je
  pravděpodobně lepší byznys než předplatné rodičů.
- Freemium: 1 dítě / 2 kroužky zdarma, rodina 49 Kč/měs. RevenueCat.
- Web admin pro organizátory (až tady; rodič web nepotřebuje).

---

## 13. Rizika

| Riziko | Dopad | Mitigace |
|---|---|---|
| GPS v halách / suterénech | **vysoký** — appka „nefunguje" | změřit v POC; velkorysý radius; flag „nepotvrzeno polohou" (4.1) |
| Apple Watch bez iPhonu (Family Setup, eSIM v CZ) | vysoký pro Fázi 2 | ověřit v POC na reálných hodinkách; fallback Wi-Fi + offline fronta |
| Push nedorazí (tokeny, APNs/FCM konfigurace, doze mode) | vysoký | end-to-end v POC; `delivered_late`; rodič vidí stav i bez pushe |
| Store review — appka pro děti, poloha nezletilých | střední | jen When-In-Use; žádná analytika/reklamy v dětské části; privacy text; rozhodnutí 4.3 |
| GDPR — data dětí | střední | rodič je zákonný zástupce a správce; žádné souřadnice; export + smazání rodiny jedním RPC |
| Dítě ztratí / vybije zařízení | střední | alert „nepřihlásila se" je přesně na tohle; later: push „nízká baterie" z hodinek |
| Dítě podvádí (mock GPS) | nízký (MVP) | Fáze 3 anti-cheat; sociální kontrola |
| Rozvrh neodpovídá realitě (prázdniny, zrušené hodiny) | střední | výjimky + „dnes odpadá" jedním tapem; prázdninový režim |
| Dvě role v jedné appce zmatou review / uživatele | nízký | child režim bez navigace; screenshoty pro obě role |

---

## 14. První kroky v terminálu

```bash
# 1. Repo: skeleton z PMTrackeru, ne fork
mkdir Automatka && cd Automatka && git init
cp -R ../PMTracker/{.github,scripts,.env.example,.gitignore} .
mkdir -p supabase/migrations supabase/functions/push docs app
cp ../PMTracker/supabase/migrations/20260618000000_init.sql \
   supabase/migrations/20261101000000_init.sql   # přepsat na rodinu (sekce 5)

# 2. Supabase (EU region), PostGIS + pg_cron + pg_net
supabase init && supabase link --project-ref <REF>
supabase db push

# 3. Flutter
flutter create app --org cz.automatka --platforms ios,android
cd app && flutter pub add supabase_flutter flutter_riverpod riverpod_annotation \
   go_router geolocator flutter_map latlong2 firebase_messaging
flutter pub add dev:build_runner dev:riverpod_generator
# iOS deployment target 15.0, SUPABASE_PUBLISHABLE_KEY — viz sekce 2

# 4. Seed + testovací účty
node --env-file=.env scripts/create-test-users.mjs   # jana, petr, babi
supabase db execute --file supabase/seed.sql
```

**Pořadí práce:** rozhodnout 4.1–4.3 → Fáze 0 body 1–2 (párování, push) →
bod 3 (hodinky POC, rozhoduje o Fázi 2) → body 4–5 → zapsat verdikty do
`docs/DECISIONS.md` → teprve pak MVP. Hodinky nestavět naplno, dokud POC
neukáže, že se na ně dá instalovat a check-in z nich projde bez iPhonu.
