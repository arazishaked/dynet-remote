# DyNet Remote (iOS)

שליטה בפרויקט Philips Dynalite מהאייפון: טעינת קובץ ‎.dlj‎ מ-Dropbox, שליטה באזורים,
פריסטים, ושליטה ישירה בכל יציאה של כל בקר דרך חיבור TCP ל-PDEG (פורט 95).

## בנייה
הקובץ ‎.ipa‎ נבנה אוטומטית ב-GitHub Actions בכל דחיפה ל-main.
אפשר גם להריץ ידנית: לשונית **Actions → Build unsigned IPA → Run workflow**.
בסיום, מורידים את ה-artifact בשם **DyNetRemote-ipa** (קובץ zip ובתוכו ‎.ipa‎).

## התקנה על האייפון (ללא תשלום)
מתקינים עם **Sideloadly** (Windows/Mac) או **SideStore** עם ה-Apple ID הרגיל.
אפליקציה חתומה ב-Apple ID חינמי פגה אחרי 7 ימים ומתקינים אותה מחדש.

בהפעלה הראשונה iOS יבקש אישור **גישה לרשת מקומית** — חובה לאשר כדי לשלוט ב-PDEG.
