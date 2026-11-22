# Wkład w projekt

[English version](CONTRIBUTING.md)

Dzięki za zainteresowanie. Mile widziane są zgłoszenia błędów, telegramy
liczników, które dekodują się źle, tłumaczenia i kod. Zgłoszenia i dyskusje
mogą być po polsku albo po angielsku.

## Jak zmiana trafia do repozytorium

Prace rozwojowe toczą się w osobnym repozytorium, a to dostaje z niego każde
wydanie. Pull request złożony tutaj jest najpierw testowany tam, w osobnej
gałęzi, na prawdziwym sprzęcie. Jeśli wymaga zmian, trafiają one także na
gałąź Twojego pull requesta (od Ciebie albo ode mnie, jeśli zaznaczone jest
„Allow edits by maintainers”), więc pull request zawsze zawiera dokładnie ten
kod, który zostanie wydany. Po wydaniu, które go zawiera, Twój pull request
jest scalany tutaj bez zmian: ma status „Merged”, a Twoje commity zostają w
historii tego repozytorium. Do tego wydania pozostaje otwarty, więc kilka dni
czekania to normalne. Jeśli pull request trzeba gruntownie przepisać, zostaje
zamiast tego zamknięty z komentarzem; autorstwo jest wtedy zachowane w drzewie
deweloperskim i w pliku z atrybucją.

Drobną poprawkę zgłoś od razu jako pull request. Przy nowej funkcji albo
czymkolwiek, co zmienia dekodowanie lub publikowanie liczników, najpierw otwórz
zgłoszenie albo dyskusję.

## Od czego zacząć czytanie

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — cały dodatek: droga telegramu
  z MQTT przez wmbusmeters do Home Assistant, działające procesy, kontrakt MQTT
  i Discovery oraz zasady, których trzeba pilnować (dodatek B). Dokument jest po
  angielsku.
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — budowanie obrazów, przypięta
  wersja wmbusmeters i wzorcowe telegramy do testów dekodowania.
- `rootfs/usr/bin/` — `bridge.sh` i `bridge-lib/` prowadzą potok,
  `webui.py` i `rootfs/usr/share/wmbus-webui/` to WebUI, `i18n.py` ma jego
  teksty.

## Sprawdzanie zmiany

**Testy statyczne** — ten sam zestaw, który CI uruchamia przy każdym pull
requeście. Potrzebują Linuksa (WSL wystarczy), basha, jq, python3 i klientów
mosquitto:

```bash
TZ=UTC LC_ALL=C.UTF-8 bash tests/run_static_tests.sh
```

Część testów ledgera porównuje z plikami zapisanymi w UTC, dlatego uruchamiaj
je z `TZ=UTC`.

**WebUI** — działa samodzielnie, poza Home Assistant, na tymczasowym katalogu
danych:

```bash
mkdir -p /tmp/wmbus-test && echo '{}' > /tmp/wmbus-test/options.json
cp config.yaml rootfs/usr/bin/   # czyta go formularz ustawień; tej kopii nie commituj
WMBUS_BASE=/tmp/wmbus-test WEBUI_PORT=8765 python3 rootfs/usr/bin/webui.py
```

Potem otwórz <http://localhost:8765>.

**Dekodowanie** sprawdzają wzorcowe telegramy: surowy telegram i oczekiwany
wynik dla każdego sterownika, zobacz „Golden decode fixtures” w
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). CI uruchamia je na przypiętej
wersji wmbusmeters.

## Licznik, który dekoduje się źle

Najbardziej przydaje się sam telegram: przycisk **Zgłoszenie…** przy liczniku
w WebUI daje surowy hex, sterownik i zdekodowane pola. Zamaskuj numer licznika
i nigdy nie publikuj klucza AES. Jeśli źle dekoduje sam wmbusmeters, poprawka
należy do jego sterownika; dodatek dostanie ją przy najbliższej aktualizacji
przypiętej wersji.

## Nowe opcje i teksty

- Wartość domyślna musi zachować dzisiejsze działanie.
- Nowa opcja w `config.yaml` potrzebuje nazwy i opisu w każdym pliku
  w `translations/` oraz tekstu `cfg_desc_<opcja>` w `i18n.py`. Bez tego Home
  Assistant i WebUI pokazują gołą nazwę bez wyjaśnienia. Teksty `cfg_desc_`
  sprawdza test.
- Teksty WebUI są w `i18n.py` w pięciu językach (en, pl, de, cs, sk). Nowy język
  to nowy blok tam i plik w `translations/`.

## Telegramy w testach

Przechwycony telegram identyfikuje prawdziwy licznik i niesie jego odczyty.
W testach używaj telegramów syntetycznych albo zamaskowanych.

## Licencja

Zobacz [LICENSE](LICENSE), [NOTICE.md](NOTICE.md) i
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Jeśli przy zmianie pomagało
Ci AI, to w porządku — napisz o tym w pull requeście i napisz, co sprawdziłeś
w prawdziwym Home Assistant.
