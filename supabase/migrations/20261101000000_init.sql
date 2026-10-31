-- ============================================================
-- Automatka — schéma, RLS, RPC, cron, push trigger
-- 20261101000000_init.sql
-- ============================================================
-- Principy (viz docs/DECISIONS.md):
--   * Souřadnice se nikdy neukládají. check_in je ověří a zapomene.
--   * Zápis do checkins / alerts / devices / pairing_codes jen přes RPC.
--   * Každá tabulka má family_id; kompozitní FK brání křížení rodin.
--   * Dítě = anonymní auth uživatel(é) napojení přes devices.auth_uid.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS postgis  WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE TYPE member_role   AS ENUM ('parent', 'guardian', 'child');
CREATE TYPE device_platform AS ENUM ('ios', 'android', 'watchos', 'wearos');
CREATE TYPE place_kind    AS ENUM ('home', 'school', 'activity', 'other');
CREATE TYPE exception_kind AS ENUM ('cancelled', 'moved');
CREATE TYPE checkin_kind  AS ENUM ('arrive', 'leave', 'home');
CREATE TYPE alert_kind    AS ENUM ('missed_arrival', 'missed_departure', 'late_home', 'sos', 'unverified');

-- ============================================================
-- TABLES
-- ============================================================

CREATE TABLE families (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL,
  plan       TEXT NOT NULL DEFAULT 'free',
  timezone   TEXT NOT NULL DEFAULT 'Europe/Prague',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Dospělý: id = auth.users.id. Dítě: vlastní UUID, zařízení se na něj
-- napojují přes devices.auth_uid — proto tu není FK na auth.users.
CREATE TABLE profiles (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id    UUID NOT NULL REFERENCES families(id) ON DELETE CASCADE,
  role         member_role NOT NULL,
  display_name TEXT NOT NULL,
  color        TEXT,
  birth_year   INTEGER,
  is_owner     BOOLEAN NOT NULL DEFAULT FALSE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (family_id, id),
  CHECK (birth_year IS NULL OR role = 'child'),
  CHECK (NOT is_owner OR role = 'parent')
);

CREATE TABLE devices (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id    UUID NOT NULL,
  profile_id   UUID NOT NULL,
  auth_uid     UUID NOT NULL UNIQUE,
  platform     device_platform NOT NULL,
  push_token   TEXT,
  model        TEXT,
  paired_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at TIMESTAMPTZ,
  revoked_at   TIMESTAMPTZ,
  UNIQUE (family_id, id),
  FOREIGN KEY (family_id, profile_id) REFERENCES profiles(family_id, id) ON DELETE CASCADE
);

CREATE TABLE pairing_codes (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id      UUID NOT NULL,
  child_id       UUID NOT NULL,
  code           TEXT NOT NULL CHECK (code ~ '^[0-9]{6}$'),
  expires_at     TIMESTAMPTZ NOT NULL,
  used_at        TIMESTAMPTZ,
  used_by_device UUID REFERENCES devices(id) ON DELETE SET NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY (family_id, child_id) REFERENCES profiles(family_id, id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX pairing_codes_live_code ON pairing_codes(code) WHERE used_at IS NULL;

-- Neúspěšné pokusy o spárování: 6 číslic se dá uhodnout, pokud se nepočítají.
CREATE TABLE pairing_attempts (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  auth_uid     UUID NOT NULL,
  attempted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX pairing_attempts_recent ON pairing_attempts(auth_uid, attempted_at);

CREATE TABLE places (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id  UUID NOT NULL REFERENCES families(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  kind       place_kind NOT NULL DEFAULT 'activity',
  address    TEXT,
  location   extensions.geography(Point, 4326) NOT NULL,
  radius_m   INTEGER NOT NULL DEFAULT 150 CHECK (radius_m BETWEEN 25 AND 2000),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (family_id, id)
);

CREATE TABLE activities (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id               UUID NOT NULL,
  place_id                UUID NOT NULL,
  name                    TEXT NOT NULL,
  color                   TEXT,
  organizer_id            UUID,  -- rezervováno pro B2B (Fáze 4)
  active                  BOOLEAN NOT NULL DEFAULT TRUE,
  arrival_tolerance_min   INTEGER NOT NULL DEFAULT 15 CHECK (arrival_tolerance_min >= 0),
  departure_tolerance_min INTEGER NOT NULL DEFAULT 15 CHECK (departure_tolerance_min >= 0),
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (family_id, id),
  FOREIGN KEY (family_id, place_id) REFERENCES places(family_id, id) ON DELETE CASCADE
);

CREATE TABLE activity_schedule (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id   UUID NOT NULL,
  activity_id UUID NOT NULL,
  weekday     INTEGER NOT NULL CHECK (weekday BETWEEN 1 AND 7),  -- ISO: 1 = pondělí
  starts      TIME NOT NULL,
  ends        TIME NOT NULL,
  valid_from  DATE NOT NULL DEFAULT CURRENT_DATE,
  valid_to    DATE,
  CHECK (ends > starts),
  CHECK (valid_to IS NULL OR valid_to >= valid_from),
  FOREIGN KEY (family_id, activity_id) REFERENCES activities(family_id, id) ON DELETE CASCADE
);

CREATE TABLE activity_exceptions (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id   UUID NOT NULL,
  activity_id UUID NOT NULL,
  date        DATE NOT NULL,
  kind        exception_kind NOT NULL,
  starts      TIME,
  ends        TIME,
  note        TEXT,
  UNIQUE (activity_id, date),
  CHECK (kind = 'cancelled' OR (starts IS NOT NULL AND ends IS NOT NULL AND ends > starts)),
  FOREIGN KEY (family_id, activity_id) REFERENCES activities(family_id, id) ON DELETE CASCADE
);

CREATE TABLE activity_children (
  family_id         UUID NOT NULL,
  activity_id       UUID NOT NULL,
  child_id          UUID NOT NULL,
  notify_parent_ids UUID[],  -- NULL = všichni dospělí v rodině
  PRIMARY KEY (activity_id, child_id),
  FOREIGN KEY (family_id, activity_id) REFERENCES activities(family_id, id) ON DELETE CASCADE,
  FOREIGN KEY (family_id, child_id) REFERENCES profiles(family_id, id) ON DELETE CASCADE
);

CREATE TABLE checkins (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id       UUID NOT NULL,
  child_id        UUID NOT NULL,
  device_id       UUID,
  place_id        UUID NOT NULL,
  activity_id     UUID,
  kind            checkin_kind NOT NULL,
  event_date      DATE NOT NULL,            -- lokální den rodiny
  client_ts       TIMESTAMPTZ NOT NULL,     -- kdy dítě zmáčklo tlačítko
  server_ts       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  verified        BOOLEAN NOT NULL,         -- nastavuje POUZE server
  delivered_late  BOOLEAN NOT NULL DEFAULT FALSE,
  client_event_id UUID,                     -- idempotence offline fronty
  FOREIGN KEY (family_id, child_id) REFERENCES profiles(family_id, id) ON DELETE CASCADE,
  FOREIGN KEY (family_id, place_id) REFERENCES places(family_id, id) ON DELETE CASCADE,
  FOREIGN KEY (family_id, activity_id) REFERENCES activities(family_id, id) ON DELETE CASCADE,
  FOREIGN KEY (family_id, device_id) REFERENCES devices(family_id, id) ON DELETE SET NULL (device_id)
);
CREATE UNIQUE INDEX checkins_client_event ON checkins(child_id, client_event_id) WHERE client_event_id IS NOT NULL;
-- Dvojí stisk nesmí poslat dva pushe. Limit: 1 výskyt kroužku za den.
CREATE UNIQUE INDEX checkins_one_per_event ON checkins(child_id, activity_id, event_date, kind) WHERE activity_id IS NOT NULL;

CREATE TABLE alerts (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id               UUID NOT NULL,
  child_id                UUID NOT NULL,
  activity_id             UUID,
  kind                    alert_kind NOT NULL,
  event_date              DATE NOT NULL,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  acknowledged_by         UUID REFERENCES profiles(id) ON DELETE SET NULL,
  acknowledged_at         TIMESTAMPTZ,
  resolved_at             TIMESTAMPTZ,
  resolved_by_checkin_id  UUID REFERENCES checkins(id) ON DELETE SET NULL,
  FOREIGN KEY (family_id, child_id) REFERENCES profiles(family_id, id) ON DELETE CASCADE,
  FOREIGN KEY (family_id, activity_id) REFERENCES activities(family_id, id) ON DELETE CASCADE
);
-- Cron nesmí stejné „nepřihlásil(a) se" založit dvakrát. SOS a unverified se neslučují.
CREATE UNIQUE INDEX alerts_idempotent ON alerts(child_id, activity_id, event_date, kind)
  NULLS NOT DISTINCT WHERE kind IN ('missed_arrival', 'missed_departure', 'late_home');

CREATE INDEX idx_profiles_family ON profiles(family_id);
CREATE INDEX idx_devices_profile ON devices(profile_id);
CREATE INDEX idx_places_family ON places(family_id);
CREATE INDEX idx_activities_family ON activities(family_id);
CREATE INDEX idx_schedule_activity ON activity_schedule(activity_id);
CREATE INDEX idx_activity_children_child ON activity_children(child_id);
CREATE INDEX idx_checkins_child_date ON checkins(child_id, event_date);
CREATE INDEX idx_alerts_family_open ON alerts(family_id, created_at DESC) WHERE resolved_at IS NULL;

-- ============================================================
-- HELPERY (SECURITY DEFINER — RLS se přes ně nezacyklí)
-- ============================================================

-- Profil přihlášeného: dospělý přímo, dítě přes nezrušené zařízení.
-- Zrušení zařízení tak platí okamžitě, i když má ještě platný JWT.
CREATE FUNCTION get_my_profile_id() RETURNS UUID
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT COALESCE(
    (SELECT id FROM profiles WHERE id = auth.uid()),
    (SELECT profile_id FROM devices WHERE auth_uid = auth.uid() AND revoked_at IS NULL)
  )
$$;

CREATE FUNCTION get_my_family_id() RETURNS UUID
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT family_id FROM profiles WHERE id = get_my_profile_id()
$$;

CREATE FUNCTION get_my_role() RETURNS member_role
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT role FROM profiles WHERE id = get_my_profile_id()
$$;

CREATE FUNCTION is_adult() RETURNS BOOLEAN
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT COALESCE(get_my_role() IN ('parent', 'guardian'), FALSE)
$$;

CREATE FUNCTION is_family_owner() RETURNS BOOLEAN
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT COALESCE((SELECT is_owner FROM profiles WHERE id = get_my_profile_id()), FALSE)
$$;

CREATE FUNCTION in_my_activity(p_activity_id UUID) RETURNS BOOLEAN
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM activity_children
                 WHERE activity_id = p_activity_id AND child_id = get_my_profile_id())
$$;

CREATE FUNCTION can_see_place(p_place_id UUID) RETURNS BOOLEAN
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM places WHERE id = p_place_id AND kind = 'home'
                   AND family_id = get_my_family_id())
      OR EXISTS (SELECT 1 FROM activities a
                 JOIN activity_children ac ON ac.activity_id = a.id
                 WHERE a.place_id = p_place_id AND ac.child_id = get_my_profile_id())
$$;

CREATE FUNCTION family_today_date(p_family UUID) RETURNS DATE
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT (NOW() AT TIME ZONE timezone)::date FROM families WHERE id = p_family
$$;

-- ============================================================
-- ROZVRH
-- ============================================================

-- Očekávané události rodiny v daný den (rozvrh + výjimky).
-- Interní: volají jen SECURITY DEFINER funkce, RLS se tu nevyhodnocuje.
CREATE FUNCTION expected_events_on(p_family UUID, p_date DATE)
RETURNS TABLE(
  family_id UUID, activity_id UUID, child_id UUID, place_id UUID,
  activity_name TEXT, event_date DATE, starts_at TIMESTAMPTZ, ends_at TIMESTAMPTZ,
  arrival_tolerance_min INTEGER, departure_tolerance_min INTEGER
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT DISTINCT ON (a.id, ac.child_id)
    a.family_id, a.id, ac.child_id, a.place_id, a.name, p_date,
    (p_date + COALESCE(x.starts, s.starts)) AT TIME ZONE f.timezone,
    (p_date + COALESCE(x.ends,   s.ends))   AT TIME ZONE f.timezone,
    a.arrival_tolerance_min, a.departure_tolerance_min
  FROM activities a
  JOIN families f ON f.id = a.family_id
  JOIN activity_children ac ON ac.activity_id = a.id
  JOIN activity_schedule s ON s.activity_id = a.id
  LEFT JOIN activity_exceptions x ON x.activity_id = a.id AND x.date = p_date
  WHERE a.family_id = p_family
    AND a.active
    AND s.weekday = EXTRACT(ISODOW FROM p_date)
    AND p_date >= s.valid_from
    AND (s.valid_to IS NULL OR p_date <= s.valid_to)
    AND (x.id IS NULL OR x.kind <> 'cancelled')
  ORDER BY a.id, ac.child_id, s.starts
$$;

CREATE VIEW expected_events AS
  SELECT e.*
  FROM families f
  CROSS JOIN LATERAL expected_events_on(f.id, family_today_date(f.id)) e;

-- Stav dne jednoho dítěte; sdílí my_today a family_today.
CREATE FUNCTION child_events_json(p_family UUID, p_child UUID, p_date DATE) RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'activity_id', e.activity_id,
    'name', e.activity_name,
    'place_id', e.place_id,
    'place_name', p.name,
    'starts_at', e.starts_at,
    'ends_at', e.ends_at,
    'status', CASE WHEN dep.client_ts IS NOT NULL THEN 'left'
                   WHEN arr.client_ts IS NOT NULL THEN 'arrived'
                   ELSE 'pending' END,
    'arrived_at', arr.client_ts,
    'left_at', dep.client_ts,
    'verified', arr.verified
  ) ORDER BY e.starts_at), '[]'::jsonb)
  FROM expected_events_on(p_family, p_date) e
  JOIN places p ON p.id = e.place_id
  LEFT JOIN checkins arr ON arr.child_id = e.child_id AND arr.activity_id = e.activity_id
    AND arr.event_date = p_date AND arr.kind = 'arrive'
  LEFT JOIN checkins dep ON dep.child_id = e.child_id AND dep.activity_id = e.activity_id
    AND dep.event_date = p_date AND dep.kind = 'leave'
  WHERE e.child_id = p_child
$$;

-- ============================================================
-- RPC — rodina a párování
-- ============================================================

-- Onboarding rodiče: založí rodinu a profil vlastníka.
CREATE FUNCTION create_family(p_family_name TEXT, p_display_name TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_family UUID;
BEGIN
  IF auth.uid() IS NULL OR COALESCE((auth.jwt()->>'is_anonymous')::boolean, FALSE) THEN
    RAISE EXCEPTION 'adult_account_required';
  END IF;
  IF get_my_profile_id() IS NOT NULL THEN RAISE EXCEPTION 'already_in_family'; END IF;

  INSERT INTO families (name) VALUES (p_family_name) RETURNING id INTO v_family;
  INSERT INTO profiles (id, family_id, role, display_name, is_owner)
  VALUES (auth.uid(), v_family, 'parent', p_display_name, TRUE);
  RETURN v_family;
END;
$$;

CREATE FUNCTION create_pairing_code(p_child_id UUID) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_family UUID := get_my_family_id();
  v_code   TEXT;
BEGIN
  IF NOT is_adult() THEN RAISE EXCEPTION 'adult_required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_child_id AND family_id = v_family AND role = 'child') THEN
    RAISE EXCEPTION 'child_not_found';
  END IF;

  DELETE FROM pairing_codes WHERE used_at IS NULL AND (child_id = p_child_id OR expires_at < NOW());

  FOR i IN 1..10 LOOP
    v_code := lpad(((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
    BEGIN
      INSERT INTO pairing_codes (family_id, child_id, code, expires_at)
      VALUES (v_family, p_child_id, v_code, NOW() + INTERVAL '15 minutes');
      RETURN v_code;
    EXCEPTION WHEN unique_violation THEN
      NULL;  -- kolize s živým kódem jiné rodiny, zkusit další
    END;
  END LOOP;
  RAISE EXCEPTION 'code_generation_failed';
END;
$$;

-- Vrací JSON místo výjimky: výjimka by vrátila i záznam o neúspěšném pokusu.
CREATE FUNCTION pair_device(
  p_code TEXT, p_platform device_platform, p_push_token TEXT DEFAULT NULL, p_model TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid    UUID := auth.uid();
  v_pc     pairing_codes%ROWTYPE;
  v_device UUID;
BEGIN
  IF v_uid IS NULL OR NOT COALESCE((auth.jwt()->>'is_anonymous')::boolean, FALSE) THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'anonymous_session_required');
  END IF;
  IF get_my_profile_id() IS NOT NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'already_paired');
  END IF;
  IF (SELECT COUNT(*) FROM pairing_attempts
      WHERE auth_uid = v_uid AND attempted_at > NOW() - INTERVAL '15 minutes') >= 5 THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'too_many_attempts');
  END IF;

  SELECT * INTO v_pc FROM pairing_codes
  WHERE code = p_code AND used_at IS NULL AND expires_at > NOW()
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO pairing_attempts (auth_uid) VALUES (v_uid);
    RETURN jsonb_build_object('ok', FALSE, 'error', 'invalid_code');
  END IF;

  INSERT INTO devices (family_id, profile_id, auth_uid, platform, push_token, model, last_seen_at)
  VALUES (v_pc.family_id, v_pc.child_id, v_uid, p_platform, p_push_token, p_model, NOW())
  ON CONFLICT (auth_uid) DO UPDATE
    SET family_id = EXCLUDED.family_id, profile_id = EXCLUDED.profile_id,
        platform = EXCLUDED.platform, push_token = EXCLUDED.push_token, model = EXCLUDED.model,
        paired_at = NOW(), last_seen_at = NOW(), revoked_at = NULL
  RETURNING id INTO v_device;

  UPDATE pairing_codes SET used_at = NOW(), used_by_device = v_device WHERE id = v_pc.id;
  DELETE FROM pairing_attempts WHERE auth_uid = v_uid;

  RETURN jsonb_build_object('ok', TRUE, 'child_id', v_pc.child_id, 'device_id', v_device,
    'display_name', (SELECT display_name FROM profiles WHERE id = v_pc.child_id));
END;
$$;

-- Registrace / obnova push tokenu (rodičovský telefon, rotace tokenu dítěte).
CREATE FUNCTION register_device(p_platform device_platform, p_push_token TEXT, p_model TEXT DEFAULT NULL)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_profile UUID := get_my_profile_id();
  v_device  UUID;
BEGIN
  IF v_profile IS NULL THEN RAISE EXCEPTION 'not_in_family'; END IF;
  -- Token patří jednomu účtu: po přihlášení jiného rodiče na tomtéž telefonu
  -- nesmí chodit pushe předchozímu.
  UPDATE devices SET push_token = NULL WHERE push_token = p_push_token AND auth_uid <> auth.uid();

  INSERT INTO devices (family_id, profile_id, auth_uid, platform, push_token, model, last_seen_at)
  VALUES (get_my_family_id(), v_profile, auth.uid(), p_platform, p_push_token, p_model, NOW())
  ON CONFLICT (auth_uid) DO UPDATE
    SET platform = EXCLUDED.platform, push_token = EXCLUDED.push_token,
        model = COALESCE(EXCLUDED.model, devices.model), last_seen_at = NOW()
  RETURNING id INTO v_device;
  RETURN v_device;
END;
$$;

CREATE FUNCTION revoke_device(p_device_id UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_auth_uid UUID;
BEGIN
  IF NOT is_adult() THEN RAISE EXCEPTION 'adult_required'; END IF;
  UPDATE devices SET revoked_at = NOW(), push_token = NULL
  WHERE id = p_device_id AND family_id = get_my_family_id() AND revoked_at IS NULL
  RETURNING auth_uid INTO v_auth_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'device_not_found'; END IF;
  DELETE FROM auth.sessions WHERE user_id = v_auth_uid;
END;
$$;

-- ============================================================
-- RPC — check-in
-- ============================================================

-- Mimo geofence bez p_unverifiable => výjimka outside_geofence, nic se neuloží.
-- p_unverifiable => souřadnice se ignorují, uloží se verified = false.
CREATE FUNCTION check_in(
  p_place_id        UUID,
  p_kind            checkin_kind,
  p_lat             DOUBLE PRECISION DEFAULT NULL,
  p_lng             DOUBLE PRECISION DEFAULT NULL,
  p_client_ts       TIMESTAMPTZ DEFAULT NULL,
  p_unverifiable    BOOLEAN DEFAULT FALSE,
  p_client_event_id UUID DEFAULT NULL
) RETURNS checkins
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_child    UUID := get_my_profile_id();
  v_family   UUID := get_my_family_id();
  v_device   UUID;
  v_tz       TEXT;
  v_ts       TIMESTAMPTZ;
  v_date     DATE;
  v_place    places%ROWTYPE;
  v_verified BOOLEAN;
  v_activity UUID;
  v_row      checkins%ROWTYPE;
BEGIN
  IF get_my_role() IS DISTINCT FROM 'child' THEN RAISE EXCEPTION 'child_required'; END IF;

  -- Opakované odeslání z offline fronty.
  IF p_client_event_id IS NOT NULL THEN
    SELECT * INTO v_row FROM checkins WHERE child_id = v_child AND client_event_id = p_client_event_id;
    IF FOUND THEN RETURN v_row; END IF;
  END IF;

  SELECT * INTO v_place FROM places WHERE id = p_place_id AND family_id = v_family;
  IF NOT FOUND OR NOT can_see_place(p_place_id) THEN RAISE EXCEPTION 'place_not_found'; END IF;
  IF p_kind = 'home' AND v_place.kind <> 'home' THEN RAISE EXCEPTION 'not_home_place'; END IF;

  -- client_ts je od klienta: budoucnost oříznout, starší než den odmítnout.
  v_ts := LEAST(COALESCE(p_client_ts, NOW()), NOW());
  IF v_ts < NOW() - INTERVAL '24 hours' THEN RAISE EXCEPTION 'stale_checkin'; END IF;

  IF p_unverifiable THEN
    v_verified := FALSE;
  ELSE
    IF p_lat IS NULL OR p_lng IS NULL THEN RAISE EXCEPTION 'location_required'; END IF;
    IF NOT ST_DWithin(
      v_place.location,
      ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography,
      v_place.radius_m
    ) THEN
      RAISE EXCEPTION 'outside_geofence';
    END IF;
    v_verified := TRUE;
  END IF;

  SELECT timezone INTO v_tz FROM families WHERE id = v_family;
  v_date := (v_ts AT TIME ZONE v_tz)::date;

  IF p_kind <> 'home' THEN
    SELECT e.activity_id INTO v_activity
    FROM expected_events_on(v_family, v_date) e
    WHERE e.child_id = v_child AND e.place_id = p_place_id
      AND v_ts BETWEEN e.starts_at - INTERVAL '60 minutes' AND e.ends_at + INTERVAL '60 minutes'
    ORDER BY ABS(EXTRACT(EPOCH FROM v_ts - e.starts_at))
    LIMIT 1;

    -- Dvojí stisk: vrátit první záznam, nový push nevznikne.
    IF v_activity IS NOT NULL THEN
      SELECT * INTO v_row FROM checkins
      WHERE child_id = v_child AND activity_id = v_activity AND event_date = v_date AND kind = p_kind;
      IF FOUND THEN RETURN v_row; END IF;
    END IF;
  END IF;

  SELECT id INTO v_device FROM devices WHERE auth_uid = auth.uid() AND revoked_at IS NULL;
  UPDATE devices SET last_seen_at = NOW() WHERE id = v_device;

  INSERT INTO checkins (family_id, child_id, device_id, place_id, activity_id, kind, event_date,
                        client_ts, verified, delivered_late, client_event_id)
  VALUES (v_family, v_child, v_device, p_place_id, v_activity, p_kind, v_date,
          v_ts, v_verified, NOW() - v_ts > INTERVAL '2 minutes', p_client_event_id)
  RETURNING * INTO v_row;

  -- Pozdě dorazivší check-in vyřeší čekající alert. Push vyjde z triggeru na
  -- checkins až po commitu, takže uvidí resolved_by_checkin_id.
  IF v_activity IS NOT NULL THEN
    UPDATE alerts SET resolved_at = NOW(), resolved_by_checkin_id = v_row.id
    WHERE child_id = v_child AND activity_id = v_activity AND event_date = v_date
      AND resolved_at IS NULL
      AND kind = CASE p_kind WHEN 'arrive' THEN 'missed_arrival'::alert_kind
                             ELSE 'missed_departure'::alert_kind END;
  END IF;

  IF NOT v_verified THEN
    INSERT INTO alerts (family_id, child_id, activity_id, kind, event_date)
    VALUES (v_family, v_child, v_activity, 'unverified', v_date);
  END IF;

  RETURN v_row;
END;
$$;

-- Jediný dotaz, který dítě a hodinky potřebují.
CREATE FUNCTION my_today() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_child  UUID := get_my_profile_id();
  v_family UUID := get_my_family_id();
  v_date   DATE;
BEGIN
  IF get_my_role() IS DISTINCT FROM 'child' THEN RAISE EXCEPTION 'child_required'; END IF;
  v_date := family_today_date(v_family);
  RETURN jsonb_build_object(
    'child_id', v_child,
    'display_name', (SELECT display_name FROM profiles WHERE id = v_child),
    'date', v_date,
    'home_place_id', (SELECT id FROM places WHERE family_id = v_family AND kind = 'home'
                      ORDER BY created_at LIMIT 1),
    'home_at', (SELECT MAX(client_ts) FROM checkins
                WHERE child_id = v_child AND event_date = v_date AND kind = 'home'),
    'events', child_events_json(v_family, v_child, v_date)
  );
END;
$$;

CREATE FUNCTION family_today() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_family UUID := get_my_family_id();
  v_date   DATE;
BEGIN
  IF NOT is_adult() THEN RAISE EXCEPTION 'adult_required'; END IF;
  v_date := family_today_date(v_family);
  RETURN jsonb_build_object(
    'date', v_date,
    'children', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', p.id, 'display_name', p.display_name, 'color', p.color,
        'home_at', (SELECT MAX(client_ts) FROM checkins
                    WHERE child_id = p.id AND event_date = v_date AND kind = 'home'),
        'events', child_events_json(v_family, p.id, v_date)
      ) ORDER BY p.display_name)
      FROM profiles p WHERE p.family_id = v_family AND p.role = 'child'
    ), '[]'::jsonb),
    'alerts', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', a.id, 'kind', a.kind, 'child_id', a.child_id,
        'child_name', p.display_name, 'activity_name', ac.name, 'created_at', a.created_at
      ) ORDER BY a.created_at DESC)
      FROM alerts a
      JOIN profiles p ON p.id = a.child_id
      LEFT JOIN activities ac ON ac.id = a.activity_id
      WHERE a.family_id = v_family AND a.resolved_at IS NULL AND a.acknowledged_at IS NULL
    ), '[]'::jsonb)
  );
END;
$$;

CREATE FUNCTION acknowledge_alert(p_alert_id UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_adult() THEN RAISE EXCEPTION 'adult_required'; END IF;
  UPDATE alerts SET acknowledged_by = get_my_profile_id(), acknowledged_at = NOW()
  WHERE id = p_alert_id AND family_id = get_my_family_id() AND acknowledged_at IS NULL;
END;
$$;

CREATE FUNCTION send_sos() RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_child  UUID := get_my_profile_id();
  v_family UUID := get_my_family_id();
  v_alert  UUID;
BEGIN
  IF get_my_role() IS DISTINCT FROM 'child' THEN RAISE EXCEPTION 'child_required'; END IF;
  -- Opakované mačkání v panice nemá zaplavit rodiče.
  SELECT id INTO v_alert FROM alerts
  WHERE child_id = v_child AND kind = 'sos' AND created_at > NOW() - INTERVAL '1 minute';
  IF FOUND THEN RETURN v_alert; END IF;

  INSERT INTO alerts (family_id, child_id, kind, event_date)
  VALUES (v_family, v_child, 'sos', family_today_date(v_family))
  RETURNING id INTO v_alert;
  RETURN v_alert;
END;
$$;

-- Volá pg_cron každou minutu. Okno 6 h: po výpadku cronu nezaplaví rodiče starými alerty.
CREATE FUNCTION raise_missed_alerts() RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_count INTEGER;
BEGIN
  WITH ev AS (
    SELECT e.*
    FROM families f
    CROSS JOIN LATERAL (VALUES (family_today_date(f.id)), (family_today_date(f.id) - 1)) AS d(day)
    CROSS JOIN LATERAL expected_events_on(f.id, d.day) e
  ), candidates AS (
    SELECT e.family_id, e.child_id, e.activity_id, e.event_date, 'missed_arrival'::alert_kind AS kind
    FROM ev e
    WHERE NOW() > e.starts_at + make_interval(mins => e.arrival_tolerance_min)
      AND NOW() < e.starts_at + make_interval(mins => e.arrival_tolerance_min) + INTERVAL '6 hours'
      AND NOT EXISTS (SELECT 1 FROM checkins c
                      WHERE c.child_id = e.child_id AND c.activity_id = e.activity_id
                        AND c.event_date = e.event_date AND c.kind = 'arrive')
    UNION ALL
    SELECT e.family_id, e.child_id, e.activity_id, e.event_date, 'missed_departure'::alert_kind
    FROM ev e
    WHERE NOW() > e.ends_at + make_interval(mins => e.departure_tolerance_min)
      AND NOW() < e.ends_at + make_interval(mins => e.departure_tolerance_min) + INTERVAL '6 hours'
      AND EXISTS (SELECT 1 FROM checkins c
                  WHERE c.child_id = e.child_id AND c.activity_id = e.activity_id
                    AND c.event_date = e.event_date AND c.kind = 'arrive')
      AND NOT EXISTS (SELECT 1 FROM checkins c
                      WHERE c.child_id = e.child_id AND c.event_date = e.event_date
                        AND (c.kind = 'home' OR (c.kind = 'leave' AND c.activity_id = e.activity_id)))
  )
  INSERT INTO alerts (family_id, child_id, activity_id, event_date, kind)
  SELECT family_id, child_id, activity_id, event_date, kind FROM candidates
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- ============================================================
-- RPC — GDPR
-- ============================================================

CREATE FUNCTION export_family() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_family UUID := get_my_family_id();
BEGIN
  IF NOT is_adult() THEN RAISE EXCEPTION 'adult_required'; END IF;
  RETURN jsonb_build_object(
    'family',     (SELECT to_jsonb(f) FROM families f WHERE id = v_family),
    'profiles',   (SELECT jsonb_agg(to_jsonb(p)) FROM profiles p WHERE family_id = v_family),
    'devices',    (SELECT jsonb_agg(to_jsonb(d) - 'push_token' - 'auth_uid') FROM devices d WHERE family_id = v_family),
    'places',     (SELECT jsonb_agg(to_jsonb(pl) - 'location') FROM places pl WHERE family_id = v_family),
    'activities', (SELECT jsonb_agg(to_jsonb(a)) FROM activities a WHERE family_id = v_family),
    'schedule',   (SELECT jsonb_agg(to_jsonb(s)) FROM activity_schedule s WHERE family_id = v_family),
    'checkins',   (SELECT jsonb_agg(to_jsonb(c)) FROM checkins c WHERE family_id = v_family),
    'alerts',     (SELECT jsonb_agg(to_jsonb(al)) FROM alerts al WHERE family_id = v_family)
  );
END;
$$;

-- Smaže rodinu včetně účtů: všechna zařízení i dospělé členy.
CREATE FUNCTION delete_family() RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_family UUID := get_my_family_id();
  v_uids   UUID[];
BEGIN
  IF NOT is_family_owner() THEN RAISE EXCEPTION 'owner_required'; END IF;
  SELECT array_agg(uid) INTO v_uids FROM (
    SELECT auth_uid AS uid FROM devices WHERE family_id = v_family
    UNION
    SELECT id FROM profiles WHERE family_id = v_family AND role <> 'child'
  ) u;
  DELETE FROM families WHERE id = v_family;
  DELETE FROM auth.users WHERE id = ANY(v_uids);
END;
$$;

-- ============================================================
-- PUSH PIPELINE
-- ============================================================

-- URL a sdílené tajemství jsou ve Vaultu (viz README). Bez nich se push přeskočí.
-- Selhání pushe nikdy nesmí shodit check-in.
CREATE FUNCTION notify_push(p_type TEXT, p_id UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_url    TEXT;
  v_secret TEXT;
BEGIN
  SELECT decrypted_secret INTO v_url FROM vault.decrypted_secrets WHERE name = 'push_function_url';
  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'push_function_secret';
  IF v_url IS NULL OR v_secret IS NULL THEN RETURN; END IF;

  PERFORM net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body := jsonb_build_object('type', p_type, 'id', p_id)
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'notify_push failed: %', SQLERRM;
END;
$$;

CREATE FUNCTION trg_checkin_push() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN PERFORM notify_push('checkin', NEW.id); RETURN NULL; END;
$$;

CREATE FUNCTION trg_alert_push() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN PERFORM notify_push('alert', NEW.id); RETURN NULL; END;
$$;

CREATE TRIGGER checkins_push AFTER INSERT ON checkins
  FOR EACH ROW EXECUTE FUNCTION trg_checkin_push();
-- unverified nemá vlastní push: rodič se to dozví z pushe check-inu.
CREATE TRIGGER alerts_push AFTER INSERT ON alerts
  FOR EACH ROW WHEN (NEW.kind <> 'unverified') EXECUTE FUNCTION trg_alert_push();

-- Komu a co poslat. Logika je v SQL, Edge Function jen doručuje.
-- Texty jsou rodově neutrální: profil pohlaví neeviduje.
CREATE FUNCTION push_payload(p_type TEXT, p_id UUID) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_family   UUID;
  v_child    UUID;
  v_activity UUID;
  v_name     TEXT;
  v_tz       TEXT;
  v_title    TEXT;
  v_body     TEXT;
  v_place    TEXT;
  v_time     TEXT;
  v_notify   UUID[];
  v_is_sos   BOOLEAN := FALSE;
  v_c        checkins%ROWTYPE;
  v_a        alerts%ROWTYPE;
  v_starts   TIMESTAMPTZ;
  v_ends     TIMESTAMPTZ;
  v_arr_tol  INTEGER;
  v_dep_tol  INTEGER;
BEGIN
  IF p_type = 'checkin' THEN
    SELECT * INTO v_c FROM checkins WHERE id = p_id;
    IF NOT FOUND THEN RETURN NULL; END IF;
    v_family := v_c.family_id; v_child := v_c.child_id; v_activity := v_c.activity_id;
  ELSIF p_type = 'alert' THEN
    SELECT * INTO v_a FROM alerts WHERE id = p_id;
    IF NOT FOUND THEN RETURN NULL; END IF;
    v_family := v_a.family_id; v_child := v_a.child_id; v_activity := v_a.activity_id;
    v_is_sos := v_a.kind = 'sos';
  ELSE
    RETURN NULL;
  END IF;

  SELECT p.display_name, f.timezone INTO v_name, v_tz
  FROM profiles p JOIN families f ON f.id = p.family_id WHERE p.id = v_child;

  IF p_type = 'checkin' THEN
    SELECT COALESCE(a.name, pl.name) INTO v_place
    FROM places pl LEFT JOIN activities a ON a.id = v_c.activity_id
    WHERE pl.id = v_c.place_id;
    v_time := to_char(v_c.client_ts AT TIME ZONE v_tz, 'HH24:MI');

    IF v_c.kind = 'home' THEN
      v_title := v_name || ' je doma';
      v_body := 'Přihlášení doma v ' || v_time;
    ELSIF v_c.kind = 'leave' THEN
      v_title := v_name || ' odchází';
      v_body := v_place || ', ' || v_time;
    ELSIF EXISTS (SELECT 1 FROM alerts WHERE resolved_by_checkin_id = v_c.id) OR v_c.delivered_late THEN
      v_title := v_name || ' se přihlašuje se zpožděním';
      v_body := v_place || ', ' || v_time;
    ELSE
      v_title := v_name || ' je na místě';
      v_body := v_place || ' (' || v_time || ')';
    END IF;

    IF NOT v_c.verified THEN v_body := v_body || ' · nepotvrzeno polohou'; END IF;
  ELSE
    IF v_activity IS NOT NULL THEN
      SELECT e.activity_name, e.starts_at, e.ends_at, e.arrival_tolerance_min, e.departure_tolerance_min
      INTO v_place, v_starts, v_ends, v_arr_tol, v_dep_tol
      FROM expected_events_on(v_family, v_a.event_date) e
      WHERE e.activity_id = v_activity AND e.child_id = v_child;
    END IF;

    IF v_a.kind = 'sos' THEN
      v_title := 'SOS: ' || v_name;
      v_body := 'Zavolej hned.';
    ELSIF v_a.kind = 'missed_arrival' THEN
      v_title := v_name || ': bez přihlášení';
      v_body := COALESCE(v_place, 'Kroužek') || ' — bez přihlášení do '
        || to_char((v_starts + make_interval(mins => v_arr_tol)) AT TIME ZONE v_tz, 'HH24:MI');
    ELSIF v_a.kind = 'missed_departure' THEN
      v_title := v_name || ': bez odhlášení';
      v_body := COALESCE(v_place, 'Kroužek') || ' — bez odhlášení do '
        || to_char((v_ends + make_interval(mins => v_dep_tol)) AT TIME ZONE v_tz, 'HH24:MI');
    ELSE
      v_title := v_name;
      v_body := 'Nové upozornění';
    END IF;
  END IF;

  IF v_activity IS NOT NULL AND NOT v_is_sos THEN
    SELECT notify_parent_ids INTO v_notify FROM activity_children
    WHERE activity_id = v_activity AND child_id = v_child;
  END IF;

  RETURN jsonb_build_object(
    'title', v_title,
    'body', v_body,
    'data', jsonb_build_object('type', p_type, 'id', p_id, 'child_id', v_child, 'critical', v_is_sos),
    'targets', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('token', d.push_token, 'platform', d.platform))
      FROM devices d
      JOIN profiles pr ON pr.id = d.profile_id
      WHERE d.family_id = v_family AND pr.role IN ('parent', 'guardian')
        AND d.revoked_at IS NULL AND d.push_token IS NOT NULL
        AND (v_notify IS NULL OR pr.id = ANY(v_notify))
    ), '[]'::jsonb)
  );
END;
$$;

-- Neplatný token se jen vymaže: revoked_at by dítěti zrušilo spárování.
CREATE FUNCTION clear_push_tokens(p_tokens TEXT[]) RETURNS VOID
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE devices SET push_token = NULL WHERE push_token = ANY(p_tokens);
$$;

-- ============================================================
-- TRIGGERY updated_at
-- ============================================================

CREATE FUNCTION update_updated_at() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

CREATE TRIGGER trg_profiles_updated_at BEFORE UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_places_updated_at BEFORE UPDATE ON places FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_activities_updated_at BEFORE UPDATE ON activities FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

ALTER TABLE families ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE pairing_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE pairing_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE places ENABLE ROW LEVEL SECURITY;
ALTER TABLE activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_schedule ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_exceptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_children ENABLE ROW LEVEL SECURITY;
ALTER TABLE checkins ENABLE ROW LEVEL SECURITY;
ALTER TABLE alerts ENABLE ROW LEVEL SECURITY;

-- families
CREATE POLICY families_select ON families FOR SELECT USING (id = get_my_family_id());
CREATE POLICY families_update ON families FOR UPDATE
  USING (id = get_my_family_id() AND is_family_owner())
  WITH CHECK (id = get_my_family_id());

-- profiles: dospělý vidí rodinu, dítě jen sebe. Dospělí zakládají jen děti.
CREATE POLICY profiles_select ON profiles FOR SELECT
  USING (id = get_my_profile_id() OR (family_id = get_my_family_id() AND is_adult()));
CREATE POLICY profiles_insert_child ON profiles FOR INSERT
  WITH CHECK (family_id = get_my_family_id() AND is_adult() AND role = 'child' AND NOT is_owner);
CREATE POLICY profiles_update ON profiles FOR UPDATE
  USING (family_id = get_my_family_id() AND is_adult() AND (role = 'child' OR id = get_my_profile_id()))
  WITH CHECK (family_id = get_my_family_id());
CREATE POLICY profiles_delete_child ON profiles FOR DELETE
  USING (family_id = get_my_family_id() AND is_adult() AND role = 'child');

-- Role, rodinu a vlastnictví nelze změnit z klienta (RLS sloupce nehlídá).
REVOKE UPDATE ON profiles FROM authenticated;
GRANT UPDATE (display_name, color, birth_year) ON profiles TO authenticated;

-- places
CREATE POLICY places_select ON places FOR SELECT
  USING (family_id = get_my_family_id() AND (is_adult() OR can_see_place(id)));
CREATE POLICY places_write ON places FOR ALL
  USING (family_id = get_my_family_id() AND is_adult())
  WITH CHECK (family_id = get_my_family_id() AND is_adult());

-- activities + rozvrh
CREATE POLICY activities_select ON activities FOR SELECT
  USING (family_id = get_my_family_id() AND (is_adult() OR in_my_activity(id)));
CREATE POLICY activities_write ON activities FOR ALL
  USING (family_id = get_my_family_id() AND is_adult())
  WITH CHECK (family_id = get_my_family_id() AND is_adult());

CREATE POLICY schedule_select ON activity_schedule FOR SELECT
  USING (family_id = get_my_family_id() AND (is_adult() OR in_my_activity(activity_id)));
CREATE POLICY schedule_write ON activity_schedule FOR ALL
  USING (family_id = get_my_family_id() AND is_adult())
  WITH CHECK (family_id = get_my_family_id() AND is_adult());

CREATE POLICY exceptions_select ON activity_exceptions FOR SELECT
  USING (family_id = get_my_family_id() AND (is_adult() OR in_my_activity(activity_id)));
CREATE POLICY exceptions_write ON activity_exceptions FOR ALL
  USING (family_id = get_my_family_id() AND is_adult())
  WITH CHECK (family_id = get_my_family_id() AND is_adult());

CREATE POLICY activity_children_select ON activity_children FOR SELECT
  USING (family_id = get_my_family_id() AND (is_adult() OR child_id = get_my_profile_id()));
CREATE POLICY activity_children_write ON activity_children FOR ALL
  USING (family_id = get_my_family_id() AND is_adult())
  WITH CHECK (family_id = get_my_family_id() AND is_adult());

-- Write-only přes RPC
CREATE POLICY checkins_select ON checkins FOR SELECT
  USING (family_id = get_my_family_id() AND (is_adult() OR child_id = get_my_profile_id()));
CREATE POLICY checkins_no_insert ON checkins FOR INSERT WITH CHECK (FALSE);
CREATE POLICY checkins_no_update ON checkins FOR UPDATE USING (FALSE);
CREATE POLICY checkins_no_delete ON checkins FOR DELETE USING (FALSE);

CREATE POLICY alerts_select ON alerts FOR SELECT
  USING (family_id = get_my_family_id() AND is_adult());
CREATE POLICY alerts_no_insert ON alerts FOR INSERT WITH CHECK (FALSE);
CREATE POLICY alerts_no_update ON alerts FOR UPDATE USING (FALSE);
CREATE POLICY alerts_no_delete ON alerts FOR DELETE USING (FALSE);

CREATE POLICY devices_select ON devices FOR SELECT
  USING (family_id = get_my_family_id() AND (is_adult() OR profile_id = get_my_profile_id()));
CREATE POLICY devices_no_insert ON devices FOR INSERT WITH CHECK (FALSE);
CREATE POLICY devices_no_update ON devices FOR UPDATE USING (FALSE);
CREATE POLICY devices_no_delete ON devices FOR DELETE USING (FALSE);

CREATE POLICY pairing_codes_select ON pairing_codes FOR SELECT
  USING (family_id = get_my_family_id() AND is_adult());
CREATE POLICY pairing_codes_no_insert ON pairing_codes FOR INSERT WITH CHECK (FALSE);
CREATE POLICY pairing_codes_no_update ON pairing_codes FOR UPDATE USING (FALSE);
CREATE POLICY pairing_codes_no_delete ON pairing_codes FOR DELETE USING (FALSE);

-- pairing_attempts: bez politik = nikdo z klienta.

-- ============================================================
-- OPRÁVNĚNÍ
-- ============================================================
-- Supabase dává na nové funkce EXECUTE i anon/authenticated, takže bez tohohle
-- by šlo raise_missed_alerts nebo push_payload volat přes REST.

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL ON expected_events FROM authenticated;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  get_my_profile_id(), get_my_family_id(), get_my_role(), is_adult(), is_family_owner(),
  in_my_activity(UUID), can_see_place(UUID),
  create_family(TEXT, TEXT), create_pairing_code(UUID),
  pair_device(TEXT, device_platform, TEXT, TEXT),
  register_device(device_platform, TEXT, TEXT), revoke_device(UUID),
  check_in(UUID, checkin_kind, DOUBLE PRECISION, DOUBLE PRECISION, TIMESTAMPTZ, BOOLEAN, UUID),
  my_today(), family_today(), acknowledge_alert(UUID), send_sos(),
  export_family(), delete_family()
TO authenticated;

GRANT EXECUTE ON FUNCTION push_payload(TEXT, UUID), clear_push_tokens(TEXT[]) TO service_role;

-- ============================================================
-- REALTIME + CRON
-- ============================================================

ALTER PUBLICATION supabase_realtime ADD TABLE checkins, alerts;

SELECT cron.schedule('raise-missed-alerts', '* * * * *', 'SELECT public.raise_missed_alerts()');
