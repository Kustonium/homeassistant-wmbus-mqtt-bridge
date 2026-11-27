# Licznik, którego wmbusmeters jeszcze nie dekoduje

*English: [UNKNOWN_METER.md](UNKNOWN_METER.md)*

Dodatek odbiera każdą ramkę, którą słyszą płytki, także od liczników, dla
których wmbusmeters nie ma sterownika. Taki licznik pojawia się w
**ODBIERANE / SZUKAJ** jako kandydat bez wartości (sterownik `unknown` albo
„unknown format signature”). Ta strona opisuje drogę od tego miejsca do
działającego licznika. Tak w listopadzie 2026 dostały sterownik podzielniki
B METERS Hydroclima 0x34, z ramek i zdjęć wyświetlacza od jednego użytkownika.

**Bez gwarancji.** Opiekun dodatku nie obiecuje, że każdy licznik da się
odczytać. Niektóre formaty są zaszyfrowane kluczem, który ma tylko firma
rozliczeniowa, i te zostają zamknięte. Wiele innych jest tylko
nieudokumentowanych albo lekko zaciemnionych, i wtedy to działa — ale czy i
kiedy, zależy od formatu i od danych, które uda się zebrać.

## 1. Sprawdź, czy naprawdę jest nieznany

- Czy dodatek jest w najnowszej wersji? Nowszy wmbusmeters może już mieć
  sterownik.
- Otwórz **Zgłoszenie…** w wierszu kandydata, żeby zobaczyć surowy telegram i
  wynik `wmbusmeters --analyze` (niczego nie musisz zgłaszać). Jeśli analiza
  mówi, że telegram jest zaszyfrowany (AES), potrzebny jest klucz od firmy
  rozliczeniowej, a nie nowy sterownik — zobacz *„Mój licznik szyfruje telegramy — co dalej?”*
  w [instrukcji](README.pl.md).
- Zanotuj producenta, wersję i typ (np. `BMP,34,08`) oraz ID licznika.

## 2. Zbierz telegramy automatycznie

Kilka telegramów nie wystarczy. Zbierz wszystkie ramki licznika przez dzień
albo dwa. Nie trzeba niczego przepisywać ręcznie — automatyzacja Home
Assistant zapisuje każdą ramkę do pliku:

1. **Ustawienia → Urządzenia i usługi → Dodaj integrację → File →
   Notification**, ścieżka pliku `/media/meter_log.txt`.
2. Utwórz tę automatyzację. Zamiast `92607351` wpisz ID licznika **w
   kolejności, w jakiej stoi w ramce**: ID `51736092` jest wysyłane jako
   `92607351` (cztery bajty odwrócone).

   ```yaml
   alias: Unknown meter telegram log
   mode: queued
   max: 100
   triggers:
     - trigger: mqtt
       topic: wmbus/+/telegram
   conditions:
     - condition: template
       value_template: "{{ (trigger.payload | upper)[8:16] == '92607351' }}"
   actions:
     - action: notify.send_message
       target:
         entity_id: notify.file
       data:
         message: "{{ now().isoformat() }} {{ trigger.topic }} {{ trigger.payload | upper }}"
   ```

   Dla kilku liczników tego samego modelu filtruj zamiast tego po producencie
   i wersji (`[4:8]` i `[16:20]` ramki, np. `B009` i `3408`).

Zostaw to na co najmniej jeden dzień roboczy: wiele liczników milczy w nocy i
w niedziele.

## 3. Odczytaj wyświetlacz w tym samym czasie

Same ramki nic nie mówią; kluczem są wartości z wyświetlacza.

- Każdy ekran, przez który przechodzi wyświetlacz, z **godziną** odczytu.
- Na początku i na końcu zbierania, i raz czy dwa pomiędzy, kiedy wartość
  się zmienia.
- Także daty z wyświetlacza (bieżąca, data rozliczenia): wartość znana z
  góry to najlepszy sposób, żeby znaleźć jej miejsce w ramce.
- Pomaga kilka liczników tego samego modelu, a najbardziej licznik, którego
  wartość się nie zmienia (kaloryfer zakręcony, brak zużycia): każda ramka
  niesie wtedy tę samą treść w innej postaci.

## 4. Zapytaj autora dodatku

W wierszu kandydata otwórz **Zgłoszenie…** i kliknij **Zapytaj autora
dodatku**. W Discussions tego repozytorium otwiera się nowe pytanie w
kategorii *Nowe liczniki / Unknown meters*, już wypełnione: model w tytule,
jeden telegram, analiza wmbusmeters i lista tego, co dopisać. Dodatek niczego
sam nie wysyła — sprawdzasz tekst i publikujesz go ze swojego konta GitHub.
Dołącz plik logu, odczyty z wyświetlacza i zdjęcie tabliczki.

Numer licznika jest w raporcie domyślnie ukryty (zastąpiony przez
`99999999`); ramki w pliku logu nadal go zawierają. Jeśli wolisz nie
publikować ich otwarcie, napisz o tym najpierw w dyskusji.

## 5. Wypróbuj sterownik od razu — szybka część

Kiedy jest plik sterownika (`.xmq`), nie czekasz na nowe wydanie:

1. Włącz **`custom_drivers_enabled`** (Sterowniki zewnętrzne) w opcjach
   dodatku. Pojawia się zakładka **STEROWNIKI**.
2. Wgraj `.xmq`. Najpierw jest sprawdzany w osobnym procesie wmbusmeters, a
   liczniki na nim działają we własnej instancji, więc wadliwy plik nie
   zatrzyma pozostałych liczników. Nazwa sterownika musi zaczynać się od
   `external_`.
3. **Pasujące liczniki w eterze** dekoduje na próbę ostatnią ramkę każdego
   licznika, który pasuje do sterownika, bez ruszania tego, co działa. Od
   razu porównujesz wartości z wyświetlaczem.
4. Wartości złe? Poprawiony plik wgrywasz tak samo i sprawdzasz na tych
   samych ramkach. Jedna runda to minuty, nie cykl wydań.
5. Wartości dobre? **Przełącz na …** ustawia licznik na ten sterownik.

Bez zaznaczenia pole plik jest traktowany jako poufny (NDA): zostaje w
dodatku i nie trafia do kopii zapasowych Home Assistant.

## 6. Do wmbusmeters

Sterownik zgodny z wyświetlaczami powinien trafić do wmbusmeters, żeby
działał u wszystkich. Sterownik wmbusmeters potrzebuje jako testów
prawdziwych telegramów ze znanymi wartościami — ramek i odczytów z kroków 2 i
3, za zgodą właściciela. Kiedy aktualizacja wmbusmeters pozna format, dodatek
może go od tego momentu przejąć.
