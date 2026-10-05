# ตั้งค่าล็อกอินของเมือง (Supabase)

ทำครั้งเดียว ใช้เวลาประมาณ 10 นาที

## 1. บอก Supabase ว่าเว็บเราอยู่ที่ไหน (ต้องทำ)
Supabase > **Authentication** > **URL Configuration**
- **Site URL**: `https://hellokaroz-del.github.io/SkyClash/lobby/`
- **Redirect URLs** กด Add URL ใส่ `https://hellokaroz-del.github.io/SkyClash/**`
- กด Save

ถ้าไม่ทำข้อนี้ ลิงก์ยืนยันอีเมลกับลิงก์ลืมรหัสผ่านจะพาไปผิดที่

## 2. อีเมล + รหัสผ่าน
Supabase > **Authentication** > **Sign In / Providers**
- ส่วน Email เปิดอยู่แล้ว ไม่ต้องทำอะไร
- **Confirm email**: ช่วงทดสอบแนะนำให้ **ปิด** แล้วกด Save changes
  เพราะอีเมลฟรีของ Supabase ส่งได้แค่ไม่กี่ฉบับต่อชั่วโมง ถ้าเปิดไว้ เพื่อนสมัครพร้อมกันหลายคนจะได้อีเมลยืนยันไม่ครบ
  (ลืมรหัสผ่านก็ใช้อีเมลชุดเดียวกัน จึงส่งได้ไม่กี่ฉบับต่อชั่วโมงเหมือนกัน)
- **Allow anonymous sign-ins**: ปิดได้เลย หน้าเมืองไม่ใช้แล้ว

## 3. ปุ่ม Google
### 3.1 ใน Google Cloud
1. เข้า https://console.cloud.google.com ด้วยบัญชี Google ของคุณ
2. มุมซ้ายบนกดเลือกโปรเจกต์ > **New Project** ตั้งชื่อ `SkyClash` > Create แล้วเลือกโปรเจกต์นี้
3. ช่องค้นหาด้านบนพิมพ์ **Google Auth Platform** แล้วกดเข้าไป > **Get started**
   - App name: `Ages of Aether`
   - User support email: อีเมลของคุณ
   - Audience: **External**
   - Contact email: อีเมลของคุณ > ติ๊กยอมรับ > Create
4. เมนูซ้าย **Audience** > กด **Publish app** (ให้ทุกคนล็อกอินได้ ไม่ใช่แค่คนที่เพิ่มชื่อไว้)
5. เมนูซ้าย **Clients** > **Create client**
   - Application type: **Web application**
   - Name: `SkyClash web`
   - **Authorized JavaScript origins** > Add URI: `https://hellokaroz-del.github.io`
   - **Authorized redirect URIs** > Add URI: `https://wslkvlysmdjxlxcihyqh.supabase.co/auth/v1/callback`
   - กด Create
6. จะเห็น **Client ID** และ **Client secret** เปิดหน้านี้ค้างไว้

### 3.2 ใน Supabase
Supabase > **Authentication** > **Sign In / Providers** > **Google**
- เปิดสวิตช์ Enable
- วาง **Client ID** และ **Client Secret** จากข้อ 6
- กด Save

**Client secret ใส่ใน Supabase เท่านั้น ห้ามส่งในแชท**

## 4. ตั้งตัวเองเป็นแอดมินอีกครั้ง
บัญชีใหม่ที่สมัครเป็นคนละบัญชีกับบัญชีทดลองเดิม หลังสมัครและตั้งชื่อในเกมแล้ว ให้รันใน SQL Editor:

```
update public.profiles set is_admin = true where name = 'GM_Karoz';
```
