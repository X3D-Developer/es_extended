<p align="center">
  <a href="../../README.md">🇬🇧 English</a> •
  <b>🇹🇭 ไทย</b>
</p>

<p align="center">
  <a href="https://fivem.x3d-developer.com/th/products/es-extended/">🌐 เว็บไซต์</a> •
  <a href="https://fivem.x3d-developer.com/th/docs/es-extended/">📖 คู่มือ</a> •
  <a href="https://discord.gg/NA5kPVynFv">💬 Discord</a> •
  <a href="https://fivem.x3d-developer.com/th/products/">🛒 สคริปต์ FiveM อื่น ๆ (ฟรี + พรีเมียม)</a>
</p>

<h1 align='center'>es_extended — X3D build</h1>

**Modified version of ESX Legacy `es_extended` 1.13.4.**
Not an official ESX release. Official project: <https://github.com/esx-framework/esx_core>

Drop-in: the resource keeps the name `es_extended`, so every `@es_extended/imports.lua`
include and every `dependencies { 'es_extended' }` on your server keeps working.

---

## ลงยังไง

1. สำรอง `es_extended` ตัวเดิมไว้ก่อน (ย้ายออกไปนอก `resources/` เฉย ๆ ก็พอ)
2. เอาโฟลเดอร์นี้วางแทนที่เดิม
3. เปิดเซิร์ฟ — ไม่ต้องรัน SQL ถ้ามีฐานข้อมูล ESX อยู่แล้ว

ตารางฐานข้อมูลตั้งชื่อได้ที่ `shared/config/main.lua` → `Config.Tables`
ค่าเริ่มต้นเป็นชื่อมาตรฐานของ ESX (`users`, `items`, `jobs`, `job_grades`, `owned_vehicles`)

ติดตั้งใหม่ทั้งหมด: รัน `es_extended.sql`

---

## แก้อะไรจากต้นฉบับบ้าง (GPL-3.0 §5a)

Modified 2026-09 by X3D-Developer, based on `esx_core` 1.13.4.

### เร็วขึ้น / กินแรมน้อยลง

- `server/classes/player.lua` — ทำ index ของ accounts/inventory/loadout ให้หาแบบ O(1)
  แทนการไล่ทีละตัว และทำ dirty-tracking ให้ `SavePlayer` encode JSON เฉพาะส่วนที่เปลี่ยน
- `server/modules/callback.lua` + `client/modules/callback.lua` — เพิ่ม timeout cleanup,
  ล้าง callback ค้างตอนผู้เล่นออก, GC sweep เป็นรอบ, รีเซ็ต ID counter
  (ต้นฉบับปล่อย callback ที่ไม่มีคนตอบค้างไว้ตลอดอายุเซิร์ฟ)
- `server/modules/onesync.lua` / `client/modules/points.lua` — ใช้ระยะยกกำลังสองแทน `sqrt`,
  ตรวจว่า entity ยังอยู่ก่อนอ่านพิกัด, sleep ตามระยะ
- `server/main.lua` — รวบการอัปเดต `GlobalState` เป็นชุด (player count ยังส่งทันที)
- `server/common.lua` — เก็บกวาด pickup ที่หมดอายุ
- `client/functions.lua` — เมนูหาแบบ O(1), ออกจากลูป vehicle extras เร็วขึ้น,
  ค้นของในกระเป๋าแบบรอบเดียว

### กันข้อมูลหาย

- `server/functions.lua` — ped ที่ถูก cull ตอนผู้เล่นหลุดจะรายงานพิกัด `(0,0,0)` และเลือด `0`
  ของเดิมเซฟทับลงฐานข้อมูล ทำให้ล็อกอินครั้งหน้าไปโผล่กลางแมพหรือเกิดมาตาย — เพิ่ม guard ทั้งสองอัน
- `Config.SaveInterval` — flush ผู้เล่นออนไลน์ทุกคนลงฐานข้อมูลเป็นรอบ (กัน rollback ตอนเซิร์ฟล่ม)
- `Core.WaitForGround` — รอพื้นโหลดก่อนปล่อยผู้เล่นลง กันตกทะลุแมพตอน spawn
- `server/common.lua` — `RefreshItems()` retry ตอนบูต ถ้า MySQL ยัง seed ไม่เสร็จ
  ตารางไอเทมจะอ่านได้ว่าง แล้วค้างว่างทั้ง session

### ความปลอดภัย

- `server/main.lua` — clamp ค่ากระสุนที่ client ส่งมา (กันกระสุนไม่จำกัด)
- `server/modules/serverlog.lua` (ใหม่) — audit log กลาง: ทุกการเปลี่ยนเงิน/ไอเทม/อาวุธ
  ผ่าน xPlayer API + join/leave/chat/death ลงตาราง พร้อมส่ง Discord webhook แยกตามชนิด
- `server/modules/restartlock.lua` (ใหม่) — 10 นาทีสุดท้ายก่อน txAdmin restart
  จะบล็อกทุก resource ที่ขยับเงิน/ไอเทม (ช่วงนั้นคือช่องดูปที่ใหญ่ที่สุด)
- `server/modules/chatfilter.lua` (ใหม่) — ตัวกรองคำต้องห้าม + เตะเมื่อครบจำนวนครั้ง

### ของใหม่อื่น ๆ

- `client/modules/world.lua` (ใหม่)
- `Config.Tables` — ตั้งชื่อตารางฐานข้อมูลได้
- `Config.ItemIconUrl` — ที่อยู่ไอคอนของ toast เงิน/ไอเทม ตรวจ `nc_inventory` / `ox_inventory` ให้อัตโนมัติ
- `Config.PlayerMaxHealth` — freemode ตัวหญิงมีเลือดสูงสุดน้อยกว่าตัวชาย และการเปลี่ยนโมเดล
  จะรีเซ็ตค่าสูงสุด ตัวนี้ทำให้เท่ากันทุก spawn (`0` = ใช้ค่าของโมเดล)
- `Config.EnterWorldTimeout` — ผู้เล่นจะลงโลกหลังกด ENTER WORLD บนหน้าโหลด
  หน้าโหลดที่ไม่รองรับก็จะถูกปล่อยลงเองเมื่อครบเวลา
- `Config.DisableWeaponWheel` — ปิดวงล้ออาวุธ (ปุ่ม TAB)
- `Config.SaveHealthAndArmor` — เก็บเลือด/เกราะข้าม session
- `esxstats` — คำสั่งคอนโซล ดูจำนวน resource / ผู้เล่น / ping ฐานข้อมูล / uptime

### Hook ที่เพิ่มเข้ามา

| Event | ยิงเมื่อ |
|---|---|
| `esx:serverEntityCreated` (server) | สร้าง vehicle/object/ped ฝั่งเซิร์ฟเวอร์ — ให้ anticheat whitelist ได้ |
| `esx:restartLock` (client) | ล็อกเศรษฐกิจเริ่มทำงาน — UI ที่ขยับเงินควรปิดตัวเอง |
| `esx:restartLockFinalFlush` (server) | 15 วินาทีก่อน restart — flush อะไรที่ต้องลงฐานข้อมูล |
| `esx_serverlog:write` (server) | `TriggerEvent('esx_serverlog:write', src, kind, data, opts)` เขียน log เอง |

### ที่เอาออก

- ทุกจุดที่ผูกกับ resource เฉพาะของเซิร์ฟเรา — ตอนนี้เป็น event กลางหรือ config หมดแล้ว
- `popcycle.dat` (ปรับมาสำหรับ `onesync_population false` ตัดรถ/คนเดินถนนทั้งแมพ)

---

## Legal

es_extended

Copyright (C) 2015-2024 Jérémie N'gadi

Modifications Copyright (C) 2026 X3D-Developer

This program Is free software: you can redistribute it And/Or modify it under the terms Of the GNU General Public License As published by the Free Software Foundation, either version 3 Of the License, Or (at your option) any later version.

This program Is distributed In the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty Of MERCHANTABILITY Or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License For more details.

You should have received a copy Of the GNU General Public License along with this program. If Not, see <http://www.gnu.org/licenses/>.
