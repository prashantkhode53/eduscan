export interface Admin {
  id: string;
  username: string;
  email: string;
  full_name?: string;
  role: string;
  is_locked: boolean;
  last_login?: string;
  created_at: string;
}

export interface Student {
  id: string;
  first_name: string;
  middle_name?: string;
  last_name: string;
  dob: string;
  gender: string;
  blood_group?: string;
  nationality?: string;
  govt_id?: string;
  institution: string;
  academic_year: string;
  class_grade: string;
  division: string;
  roll_no?: number;
  stream?: string;
  admission_date: string;
  parent_name: string;
  parent_relation?: string;
  mobile: string;
  email?: string;
  address?: string;
  known_allergies?: string;
  medical_conditions?: string;
  emergency_contact?: string;
  transport_route?: string;
  face_embedding: number[];
  face_quality?: number;
  status: 'active' | 'inactive';
  created_at: string;
  updated_at: string;
}

export interface Attendance {
  id: string;
  student_id: string;
  date: string;
  time_in?: string;
  time_out?: string;
  duration_mins?: number;
  status: 'present' | 'absent' | 'late';
  checkin_mode: 'face_auto' | 'admin_manual';
  checkout_mode: 'face_auto' | 'admin_manual' | 'not_recorded';
  confidence_in?: number;
  confidence_out?: number;
  remarks?: string;
  marked_by?: string;
  created_at: string;
}

export interface ScanRequest {
  embedding: number[];
  mode: 'checkin' | 'checkout';
  class_id: string;
  timestamp: string;
}

export type ScanAction =
  | 'checkin'
  | 'checkout'
  | 'duplicate'
  | 'unknown'
  | 'error'
  | 'outside_hours'
  | 'already_complete';

export interface ScanResponse {
  success: boolean;
  action: ScanAction;
  student?: Partial<Student>;
  time_in?: string;
  time_out?: string;
  duration_mins?: number;
  message: string;
}

// ── Academy / multi-tenant types ─────────────────────────────────────────────

export type AcademyUserRole = 'admin' | 'teacher' | 'student' | 'parent';

export interface AcademyUser {
  userId: string;
  academyId: string;
  academyName: string;
  role: AcademyUserRole;
  name: string;
  email: string;
  type: 'academy';
}

export interface Academy {
  id: string;
  name: string;
  slug: string;
  neon_branch_id?: string;
  admin_name: string;
  admin_email: string;
  phone?: string;
  address?: string;
  logo_url?: string;
  status: 'active' | 'inactive';
  created_at: string;
}

// ── Global Express augmentation ───────────────────────────────────────────────

export interface ApiResponse<T> {
  success: boolean;
  data?: T;
  message: string;
  error?: string;
}

export interface DashboardStats {
  total_students: number;
  present_today: number;
  absent_today: number;
  unknown_faces: number;
  attendance_percentage: number;
}

export interface BatchAttendanceRequest {
  records: Omit<Attendance, 'id' | 'created_at'>[];
}

export interface AuthRequest {
  username: string;
  password: string;
}

export interface AuthResponse {
  token: string;
  admin: Admin;
}

export interface ReportFilter {
  date_from?: string;
  date_to?: string;
  class_grade?: string;
  division?: string;
  student_id?: string;
  format?: 'json' | 'csv' | 'pdf';
}

export interface WeeklyClassStat {
  class_grade: string;
  division: string;
  date: string;
  present: number;
  total: number;
  percentage: number;
}

export interface AttendanceSummary {
  total_days: number;
  present_days: number;
  absent_days: number;
  late_days: number;
  percentage: number;
}

declare global {
  namespace Express {
    interface Request {
      admin?: Admin;
      academyUser?: AcademyUser;
    }
  }
}
