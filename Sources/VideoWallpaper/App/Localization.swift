import Foundation

enum Lang: String, Codable {
    case zh, en
}

@MainActor
struct L {
    static var lang: Lang = .en

    static var dynamicScreens: String { lang == .zh ? "设置动态壁纸" : "Dynamic Wallpaper" }
    static var staticScreens: String { lang == .zh ? "设置退出状态壁纸" : "Idle Wallpaper" }
    static var setWallpaperAll: String { lang == .zh ? "统一设置动态壁纸…" : "Set Dynamic Wallpaper for All…" }
    static var setStaticAll: String { lang == .zh ? "统一设置退出状态壁纸…" : "Set Idle Wallpaper for All…" }
    static var pauseAll: String { lang == .zh ? "全部暂停" : "Pause All" }
    static var resumeAll: String { lang == .zh ? "全部继续" : "Resume All" }
    static var stopAll: String { lang == .zh ? "全部停止" : "Stop All" }
    static var restoreAll: String { lang == .zh ? "全部恢复" : "Restore All" }
    static var solidBlack: String { lang == .zh ? "纯黑" : "Solid Black" }
    static var chooseImage: String { lang == .zh ? "选择图片…" : "Choose Image…" }
    static var language: String { lang == .zh ? "语言" : "Language" }
    static var quit: String { lang == .zh ? "退出" : "Quit" }
    static var selectWallpaper: String { lang == .zh ? "选择壁纸…" : "Select Wallpaper…" }
    static var pause: String { lang == .zh ? "暂停" : "Pause" }
    static var resume: String { lang == .zh ? "继续" : "Resume" }
    static var stop: String { lang == .zh ? "停止" : "Stop" }
    static var restore: String { lang == .zh ? "恢复" : "Restore" }
    static var selectWallpaperTitle: String { lang == .zh ? "选择壁纸（视频/图片/WE文件夹）" : "Select Wallpaper (Video/Image/WE Folder)" }
    static var selectImageTitle: String { lang == .zh ? "选择壁纸图片" : "Select Wallpaper Image" }
    static var current: String { lang == .zh ? "当前" : "Current" }
    static var unsupportedWE: String { lang == .zh ? "不支持的 WE 壁纸类型" : "Unsupported WE wallpaper type" }
    static var unsupportedFile: String { lang == .zh ? "不支持的文件类型" : "Unsupported file type" }
    static var muteAudio: String { lang == .zh ? "静音" : "Mute Audio" }
    static var unmuteAudio: String { lang == .zh ? "取消静音" : "Unmute Audio" }
}
