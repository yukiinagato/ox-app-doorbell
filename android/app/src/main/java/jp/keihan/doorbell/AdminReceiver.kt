// Device Owner 化のための DeviceAdminReceiver (deploy/provision/android/provision.md 参照)。
// DO の時 MainActivity が setLockTaskPackages + startLockTask で完全 kiosk になる。
package jp.keihan.doorbell

import android.app.admin.DeviceAdminReceiver

class AdminReceiver : DeviceAdminReceiver()
