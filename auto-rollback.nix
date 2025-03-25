# This file should be imported in your configuration.nix
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.auto-rollback;
  
  # Script to detect generation changes
  genChangeDetectorScript = pkgs.writeShellScript "gen-change-detector" ''
    #!/usr/bin/env bash
    set -euo pipefail

    # Get current generation number
    CURRENT_GEN=$(readlink -f /run/current-system | grep -o '[0-9]\+' | head -n1)
    
    # Read last saved generation
    if [ -f /var/lib/auto-rollback/last-gen ]; then
      LAST_GEN=$(cat /var/lib/auto-rollback/last-gen)
    else
      # If no saved generation, just save current and exit
      mkdir -p /var/lib/auto-rollback
      echo "$CURRENT_GEN" > /var/lib/auto-rollback/last-gen
      exit 0
    fi
    
    # Check if generation changed
    if [ "$CURRENT_GEN" != "$LAST_GEN" ]; then
      # Save new generation
      echo "$CURRENT_GEN" > /var/lib/auto-rollback/last-gen
      
      # Mark that confirmation is needed and store the previous generation for potential rollback
      echo "$LAST_GEN" > /var/lib/auto-rollback/rollback-gen
      touch /var/lib/auto-rollback/confirmation-needed
      
      # Start the confirmation timer service
      systemctl start auto-rollback-timer.service
      
      # Notify all logged-in users
      for USER_WITH_TTY in $(w -h | awk '{print $1}' | sort -u); do
        USER_DISPLAY=$(w | grep "$USER_WITH_TTY" | grep -o ':[0-9]\+' | head -n1)
        if [ -n "$USER_DISPLAY" ]; then
          su - "$USER_WITH_TTY" -c "DISPLAY=$USER_DISPLAY DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$USER_WITH_TTY")/bus notify-send -u critical 'NixOS Generation Change' 'System configuration has changed. Please run \"nixos-confirm\" within 5 minutes to prevent rollback.'"
        fi
      done
      
      # Broadcast message to all terminals
      echo "NixOS configuration generation has changed. Please run 'nixos-confirm' within 5 minutes to prevent automatic rollback." | wall
    fi
  '';
  
  # Script for confirmation command
  confirmScript = pkgs.writeShellScript "nixos-confirm" ''
    #!/usr/bin/env bash
    
    if [ -f /var/lib/auto-rollback/confirmation-needed ]; then
      rm -f /var/lib/auto-rollback/confirmation-needed
      systemctl stop auto-rollback-timer.service
      echo "System change confirmed. Automatic rollback cancelled."
    else
      echo "No pending system changes to confirm."
    fi
  '';
  
  # Script for rollback
  rollbackScript = pkgs.writeShellScript "auto-rollback" ''
    #!/usr/bin/env bash
    set -euo pipefail
    
    if [ -f /var/lib/auto-rollback/confirmation-needed ]; then
      if [ -f /var/lib/auto-rollback/rollback-gen ]; then
        ROLLBACK_GEN=$(cat /var/lib/auto-rollback/rollback-gen)
        echo "No confirmation received. Rolling back to generation $ROLLBACK_GEN..."
        
        # Actual rollback
        /run/current-system/sw/bin/nixos-rebuild switch --rollback
        
        echo "Rollback complete. System has been switched to the previous generation."
        wall "ATTENTION: No confirmation received for system change. System has been rolled back to the previous generation."
      else
        echo "Error: Rollback generation not found."
        exit 1
      fi
    else
      echo "No rollback needed."
    fi
  '';
  
  # Command to let users confirm the system change
  nixosConfirmCommand = pkgs.writeShellScriptBin "nixos-confirm" ''
    exec ${confirmScript}
  '';

in {
  options.services.auto-rollback = {
    enable = mkEnableOption "NixOS automatic rollback system";
    timeoutMinutes = mkOption {
      type = types.int;
      default = 5;
      description = "Minutes to wait for confirmation before rolling back";
    };
  };

  config = mkIf cfg.enable {
    # Install the confirmation command for users
    environment.systemPackages = [ nixosConfirmCommand ];
    
    # Create directory for state files
    system.activationScripts.auto-rollback-dir = ''
      mkdir -p /var/lib/auto-rollback
      chmod 755 /var/lib/auto-rollback
    '';
    
    # Service that detects generation changes after a rebuild or reboot
    systemd.services.auto-rollback-detector = {
      description = "NixOS Generation Change Detector";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = genChangeDetectorScript;
      };
    };
    
    # Timer service that will perform the rollback if no confirmation received
    systemd.services.auto-rollback-timer = {
      description = "NixOS Automatic Rollback Timer";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = rollbackScript;
      };
    };
    
    # Timer that activates the rollback after the timeout
    systemd.timers.auto-rollback-timer = {
      description = "Timer for NixOS Automatic Rollback";
      timerConfig = {
        OnActiveSec = "${toString cfg.timeoutMinutes}m";
        AccuracySec = "1s";
      };
    };
    
    # Service that runs on every boot
    systemd.services.auto-rollback-boot = {
      description = "NixOS Generation Change Detector (Boot)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = genChangeDetectorScript;
      };
    };
    
    # PAM module to show message after login
    security.pam.services = builtins.listToAttrs (map (pamService: {
      name = pamService;
      value = {
        text = ''
          session optional ${pkgs.pam_script}/lib/security/pam_script.so dir=${pkgs.writeTextDir "login_check.sh" ''
            #!/bin/sh
            if [ -f /var/lib/auto-rollback/confirmation-needed ]; then
              echo "WARNING: NixOS configuration has changed. Please run 'nixos-confirm' within the timeout to prevent automatic rollback."
            fi
          ''}
        '';
      };
    }) [ "login" "sshd" ]);
  };
}
