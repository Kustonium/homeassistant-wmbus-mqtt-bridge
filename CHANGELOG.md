## 1.5.16 (2026-05-30)

- fix(bridge): WARTOSC = total_m3 a nie target_m3 (izar i inne wodomierze)
- fix(bridge): licznik z literami w id (np. izar) nie dekodowal — id= teraz lowercase
- fix(bridge): wykrycie kandydata bez AES restartowalo glowny pipeline DECODE
- fix: pokazuj kandydata z raw telegramu
- fix: wyciagaj ID licznika z raw telegramu hex
