{ config, ... }:
{
  imports = [
    # ...your other imports
    ./auto-rollback.nix
  ];
  
  # Enable the auto-rollback service
  services.auto-rollback = {
    enable = true;
    # Optional: customize these settings
    sshConfirmPort = 2323;  # Port for SSH confirmation
    rebootAfterRollback = true;  # Whether to reboot after rollback
  };
}
