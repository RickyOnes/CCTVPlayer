import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { audio } from '@kit.AudioKit';

const DOMAIN = 0x0000;

/**
 * EntryAbility - TVPlayer 主 Ability
 *
 * 职责：
 *  - 管理应用生命周期（前台/后台）
 *  - 后台音频模式下保持 AVSession 活跃，确保播控中心正常工作
 *  - 前台恢复时同步音频状态
 */
export default class EntryAbility extends UIAbility {
  /** AudioManager 实例：后台模式下管理音频焦点 */
  private audioMgr: audio.AudioManager | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    // ★ 前台恢复时无需额外操作：AVSession 在 Index.ets 中已创建并持续活跃，
    //   系统播控中心会自动显示当前播放状态。
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // ★ 后台模式：由于 module.json5 已声明 backgroundModes: ["audioPlayback"]，
    //   系统会允许应用在后台继续播放音频（AVSession 保持活跃）。
    //   此处无需暂停音频——后台播放是核心功能（息屏/锁屏直播观看）。
  }
}