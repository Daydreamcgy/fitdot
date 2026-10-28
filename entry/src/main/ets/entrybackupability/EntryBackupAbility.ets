import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';
import { Logger } from '../common/Logger';
import { Constants } from '../common/Constants';

export default class EntryBackupAbility extends BackupExtensionAbility {
  async onBackup(): Promise<void> {
    Logger.info(Constants.TAG, 'onBackup ok');
  }

  async onRestore(bundleVersion: BundleVersion): Promise<void> {
    Logger.info(Constants.TAG, `onRestore ok ${JSON.stringify(bundleVersion)}`);
  }
}
