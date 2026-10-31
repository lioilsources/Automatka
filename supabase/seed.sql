-- ============================================================
-- Automatka — Seed (rodina Novákovi)
-- ============================================================
-- Předpoklad: node --env-file=.env scripts/create-test-users.mjs
-- Spuštění:   npx supabase db query --linked --file supabase/seed.sql
--             (lokálně bez --linked, viz README)
--
-- Účty (heslo Automatka123!):
--   jana@automatka.test  rodič, vlastník rodiny
--   petr@automatka.test  rodič
--   babi@automatka.test  guardian
--
-- Skript je idempotentní. Poslední výstup vypíše párovací kódy dětí.
-- Kódy mají platnost 1 rok — pouze pro test, skutečné platí 15 minut.
-- ============================================================

DO $$
DECLARE
  v_family UUID := '00000000-0000-0000-0000-000000000001';
  v_anicka UUID := '00000000-0000-0000-0000-00000000a001';
  v_kuba   UUID := '00000000-0000-0000-0000-00000000a002';
  v_home   UUID := '00000000-0000-0000-0000-00000000b001';
  v_school UUID := '00000000-0000-0000-0000-00000000b002';
  v_ddm    UUID := '00000000-0000-0000-0000-00000000b003';
  v_hala   UUID := '00000000-0000-0000-0000-00000000b004';
  v_babi_p UUID := '00000000-0000-0000-0000-00000000b005';
  v_keram  UUID := '00000000-0000-0000-0000-00000000c001';
  v_florb  UUID := '00000000-0000-0000-0000-00000000c002';
  v_jana   UUID;
  v_petr   UUID;
  v_babi   UUID;
BEGIN
  SELECT id INTO v_jana FROM auth.users WHERE email = 'jana@automatka.test';
  SELECT id INTO v_petr FROM auth.users WHERE email = 'petr@automatka.test';
  SELECT id INTO v_babi FROM auth.users WHERE email = 'babi@automatka.test';

  IF v_jana IS NULL OR v_petr IS NULL OR v_babi IS NULL THEN
    RAISE EXCEPTION 'Chybí auth uživatelé. Spusť nejdřív: node --env-file=.env scripts/create-test-users.mjs';
  END IF;

  INSERT INTO families (id, name) VALUES (v_family, 'Novákovi') ON CONFLICT (id) DO NOTHING;

  INSERT INTO profiles (id, family_id, role, display_name, color, birth_year, is_owner) VALUES
    (v_jana,   v_family, 'parent',   'Jana',   NULL,      NULL, TRUE),
    (v_petr,   v_family, 'parent',   'Petr',   NULL,      NULL, FALSE),
    (v_babi,   v_family, 'guardian', 'Babi',   NULL,      NULL, FALSE),
    (v_anicka, v_family, 'child',    'Anička', '#E5579A', EXTRACT(YEAR FROM CURRENT_DATE)::int - 9,  FALSE),
    (v_kuba,   v_family, 'child',    'Kuba',   '#2E86DE', EXTRACT(YEAR FROM CURRENT_DATE)::int - 12, FALSE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO places (id, family_id, name, kind, address, location, radius_m) VALUES
    (v_home,   v_family, 'Domov',    'home',     'Korunní 810/104, Praha 10',
     ST_SetSRID(ST_MakePoint(14.4587, 50.0745), 4326)::geography, 100),
    (v_school, v_family, 'ZŠ',       'school',   'Kodaňská 658/16, Praha 10',
     ST_SetSRID(ST_MakePoint(14.4640, 50.0680), 4326)::geography, 150),
    (v_ddm,    v_family, 'DDM',      'activity', 'Karlínské náměstí 7, Praha 8',
     ST_SetSRID(ST_MakePoint(14.4502, 50.0925), 4326)::geography, 150),
    (v_hala,   v_family, 'Hala',     'activity', 'Na Folimance 2, Praha 2',
     ST_SetSRID(ST_MakePoint(14.4340, 50.0690), 4326)::geography, 200),
    (v_babi_p, v_family, 'U babičky', 'other',   'Budějovická 15, Praha 4',
     ST_SetSRID(ST_MakePoint(14.4493, 50.0442), 4326)::geography, 100)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO activities (id, family_id, place_id, name, color) VALUES
    (v_keram, v_family, v_ddm,  'Keramika', '#E5579A'),
    (v_florb, v_family, v_hala, 'Florbal',  '#2E86DE')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO activity_children (family_id, activity_id, child_id) VALUES
    (v_family, v_keram, v_anicka),
    (v_family, v_florb, v_kuba)
  ON CONFLICT DO NOTHING;

  -- Út keramika, po + čt florbal
  INSERT INTO activity_schedule (family_id, activity_id, weekday, starts, ends, valid_from)
  SELECT v_family, v.activity_id, v.weekday, v.starts::time, v.ends::time, DATE '2026-09-01'
  FROM (VALUES
    (v_keram, 2, '16:00', '17:30'),
    (v_florb, 1, '17:00', '18:30'),
    (v_florb, 4, '17:00', '18:30')
  ) AS v(activity_id, weekday, starts, ends)
  WHERE NOT EXISTS (
    SELECT 1 FROM activity_schedule s WHERE s.activity_id = v.activity_id AND s.weekday = v.weekday
  );

  DELETE FROM pairing_codes WHERE child_id IN (v_anicka, v_kuba) AND used_at IS NULL;
  INSERT INTO pairing_codes (family_id, child_id, code, expires_at) VALUES
    (v_family, v_anicka, '111111', NOW() + INTERVAL '1 year'),
    (v_family, v_kuba,   '222222', NOW() + INTERVAL '1 year');
END;
$$;

SELECT p.display_name AS dite, c.code AS parovaci_kod
FROM pairing_codes c JOIN profiles p ON p.id = c.child_id
WHERE c.used_at IS NULL AND p.family_id = '00000000-0000-0000-0000-000000000001'
ORDER BY p.display_name;
