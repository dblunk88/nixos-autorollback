{ config, pkgs, ... }:

{
  imports = [
    # Your other imports
    ./auto-rollback.nix
  ];

  # Enable the auto-rollback service
  services.auto-rollback = {
    enable = true;
    timeoutMinutes = 5;  # Default value, can be adjusted
  };

  # Rest of your configuration
}
