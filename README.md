# Clocking

**Employee time clock for small clinics and local businesses: QR codes, work schedules and reports.**
No server. No internet. No accounts.

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Flutter](https://img.shields.io/badge/Flutter-3.10%2B-02569B?logo=flutter)](https://flutter.dev)
[![Android](https://img.shields.io/badge/Android-7.0%2B-3DDC84?logo=android)](https://www.android.com)

---

## What is Clocking?

Clocking is an open-source Flutter app for Android that turns one phone or tablet at the entrance
into a time clock. The manager adds the employees by hand, and each employee gets a QR code. The
employee shows the code when arriving and when leaving, either printed on a card or as a picture on
their own phone. Employees don't need the app. The same phone keeps the work schedule and produces
attendance reports. Everything stays on the phone, with no server and no internet connection.

---

## Features

- **Employees** added by hand (name, position, phone, note). They can be deactivated, which keeps
  their records in reports, or deleted.
- **A QR code per employee:** printable cards (PDF, 6 per A4 page) or an image to send to the
  employee. A lost code can be replaced, and the old one stops working.
- **Clock in / out by scanning:** the scan switches between in and out by itself. A second scan
  within a few minutes is ignored. A wrong in/out can be fixed with one tap right after the scan.
  Night shifts and 24-hour duties are handled.
- **Attendance per day:** who is in, who has left and who is missing. The manager can add, correct
  or delete clockings, and every correction stays marked as one.
- **Work schedule generated with one button:** each employee has a saved work program,
  - fixed hours (chosen weekdays, one shift);
  - rotating shifts (2 or 3 shifts, changing every N days or weekly);
  - a shift team with a coverage rule: at least N employees on each shift every day (for example at
    least one nurse from 8:00 and the rest from 11:00, or one receptionist on the day shift and one on
    the night shift). The team is shared out day by day in rotation, with 24h off after a 12h shift,
    and days off follow the norm and the leave. Days the minimum can't be covered are listed;
  - continuous cycles (12/24, 12/48, 24/48, 24/72 or a custom sequence) that carry on from month to month;
  - automatic monthly norm: the chosen shifts are spread over the month to cover the legal norm
    (working days × daily norm, minus leave), with a day off after long or night shifts.

  The manager only marks the exceptions (days off and leave: annual, sick, unpaid, other) for one or
  more employees, then **Generate schedule** fills in the month for everyone and keeps the
  exceptions. Romanian public holidays (Orthodox Easter included) are days off unless the program
  works on holidays. Each employee's scheduled hours are shown against the month's norm. The month
  can still be edited day by day and is exported to PDF or CSV. Employees with **flexible hours**
  have no schedule: their hours come from the clockings and are compared with the norm.
- **Reports** for any period, for one employee or all of them: hours worked and scheduled, late
  arrivals, early departures, overtime, absences, leave days and incomplete records. Exported as PDF
  or CSV (Excel).
- **Manager PIN:** on the entrance phone, employees only see the clocking screen.
- **Light and dark mode**, automatic or chosen in Settings.
- **Two-phone sync over SMS**, with messages signed by a pairing code entered on both phones. For
  example, the entrance phone scans and the manager's phone receives every clocking.
- **Encrypted backup**, daily and manual, to phone storage or a USB stick
- **Romanian and English**, chosen from the globe icon in the app bar (on first launch: Romanian on a Romanian phone, English otherwise)
- 30-day free trial, then an activation license (see [Free Trial & Activation License](#free-trial--activation-license))

---

## How It Works

```
Manager adds an employee     →  the app creates the employee's QR code
Employee arrives, shows QR   →  CLOCK IN 08:02
Employee leaves, shows QR    →  CLOCK OUT 16:05
Manager opens Reports        →  hours, lateness, overtime, absences — PDF / Excel
```

The QR code holds the employee's id and a random secret (`CLK1:<id>:<secret>`). A code made up
by hand with someone's id is rejected, and replacing a lost code invalidates the old one.

---

## Free Trial & Activation License

The complete source code, including the 30-day trial check, is published here under the AGPL-3.0.
**The code is not sold**, and the rights the AGPL gives you (to use, study, modify and redistribute it)
don't depend on buying anything.

What is sold is an **activation license**: a signed file, tied to one install code (Business ID),
that unlocks the app after the 30-day free trial in the Clocking app distributed by Volt Academy
(the Android APK available at [voltacademy.app/clocking.html](https://voltacademy.app/clocking.html)).

| Period | Requirement |
|---|---|
| First 30 days after install | Free, all features |
| After the trial | Activation license — 30, 60 or 180 days, or permanent |

Without a license after the trial, clocking in by scanning keeps working, so no attendance data is
lost. Adding employees, the schedule and reports are locked until the license is activated.

Licenses are bought at [voltacademy.app/clocking.html](https://voltacademy.app/clocking.html#licentiere),
where current prices are listed. Expirable licenses bought for the same install code add up, and the
license becomes permanent automatically once their total reaches the price of a permanent license.

To activate a license:

1. Open the **License** screen in the app and copy the **Installation code**.
2. Buy a license on the site with that code and download `clocking_license.json`.
3. Back on the **License** screen, tap **Select the license file** and pick the downloaded file.

One license covers two synced phones. Once sync is set up, tap **Send the license to the partner phone**
and the license is sent over SMS to the second phone.

Questions about licenses: [voltacademy.app/contact.html](https://voltacademy.app/contact.html)

---

## Privacy

All data (employees, clockings, schedules) stays on the phone. The release build has no
Internet permission. The QR scanner (Google ML Kit, through `mobile_scanner`) runs on the device,
and its usage-diagnostics uploader is removed from the app. The only data that leaves the phone is
what you choose to send: sync SMS to your own second phone, exports you share and backups you save.

---

## Platform Support

Clocking is built for **Android** only. SMS sync, backup and license import use Android
platform channels (Kotlin, in `android/app/src/main/kotlin`).

---

## Getting Started

### Requirements
- Flutter SDK 3.10+
- Android SDK (minSdk 24 — Android 7.0)

### Run

```bash
git clone https://github.com/adyptc-prog/clocking.git
cd clocking
flutter pub get
flutter run
```

### Test

```bash
flutter test
flutter analyze
cd android && ./gradlew :app:testDebugUnitTest
```

### Build release APK

```bash
flutter build apk --release
```

Release builds are signed with the keystore described in `android/key.properties`, which is not
part of this repository. To build your own release, create that file for your own keystore.

The app icon is drawn by `tools/make_icon.py` (Python + Pillow), which also writes the Android
launcher resources.

---

## Author

**Adrian Petcu** — [Volt Academy](mailto:adyptc@gmail.com)

---

## Contributing

Pull requests are welcome. For major changes, open an issue first.

All contributions must be compatible with the AGPL-3.0 license.

---

## License

**Clocking — Employee Time Clock App**<br>
Copyright (C) 2026 Adrian Petcu — Volt Academy

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published
by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

The full text of the **GNU Affero General Public License v3.0** is in [LICENSE](LICENSE).

The Roboto font in `assets/fonts` (used in PDF exports) is licensed under the Apache License 2.0,
see `assets/fonts/LICENSE-Roboto.txt`.

SPDX-License-Identifier: AGPL-3.0-or-later
