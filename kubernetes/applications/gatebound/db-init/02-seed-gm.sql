-- Seedar GM-kontot i Docker-databasen vid första starten (matchar native-setupen).
-- Körs efter 01-schema.sql. Lösenord lagras som SHA1, precis som TFS förväntar.
-- Konto: 951951 / CHANGEME  ->  karaktär Carnufex (group_id 6 = god, full admin).

INSERT INTO accounts (name, password, type, creation)
VALUES ('951951', SHA1('CHANGEME'), 6, UNIX_TIMESTAMP());

INSERT INTO players
  (name, group_id, account_id, vocation, level, experience,
   health, healthmax, mana, manamax, cap, sex, looktype, town_id, posx, posy, posz)
VALUES
  ('Carnufex', 6, LAST_INSERT_ID(), 4, 8, 6400,
   185, 185, 90, 90, 470, 1, 75, 1, 0, 0, 0);
