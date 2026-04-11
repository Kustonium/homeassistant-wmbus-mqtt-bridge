## 1.3.9
EN

Improved validation and UI guidance for meter decryption keys.
The key field now accepts only an empty value or a valid 32-character hexadecimal AES key, making invalid short values like 000000000000 fail early in the add-on configuration instead of later in wmbusmeters.

PL

Poprawiono walidację i opis w interfejsie dla kluczy dekodujących liczników.
Pole key akceptuje teraz wyłącznie pustą wartość albo poprawny 32-znakowy klucz AES w zapisie hex, dzięki czemu błędne krótkie wartości, takie jak 000000000000, są odrzucane już na etapie konfiguracji dodatku, a nie dopiero przez wmbusmeters.