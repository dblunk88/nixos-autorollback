# NixOS Auto-Rollback System
# Save this as /etc/nixos/auto-rollback.nix and import it in your configuration.nix

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.auto-rollback;
  
  # Script to check if generation has changed
  checkGenScript = pkgs.writeScript "check-generation-change" ''
    #!/bin/sh
    
    # Store the current generation number
    CURRENT_GEN=$(readlink -f /run/current-system | grep -o '[0-9]\+' | head -n1)
    
    # Get the previous generation from our state file, if it exists
    if [ -f /var/lib/auto-rollback/last-gen ]; then
      PREV_GEN=$(cat /var/lib/auto-rollback/last-gen)
    else
      # First run, create directory and store current gen
      mkdir -p /var/lib/auto-rollback
      echo "$CURRENT_GEN" > /var/lib/auto-rollback/last-gen
      exit 0  # No need to trigger confirmation for the first run
    fi
    
    # If generation changed, trigger the confirmation service
    if [ "$CURRENT_GEN" != "$PREV_GEN" ]; then
      echo "$CURRENT_GEN" > /var/lib/auto-rollback/last-gen
      echo "Generation changed from $PREV_GEN to $CURRENT_GEN"
      exit 0  # Return success to trigger the confirmation
    else
      exit 1  # No change, don't trigger confirmation
    fi
  '';
  
  # Script for the confirmation service
  confirmationScript = pkgs.writeScript "generation-confirmation" ''
    #!/bin/sh
    
    # Cancel any existing rollback timers
    systemctl stop auto-rollback-timer.timer || true
    systemctl stop auto-rollback-timer.service || true
    
    # Start a new timer
    systemctl start auto-rollback-timer.timer
    
    # Function to clean up on exit
    cleanup() {
      systemctl stop auto-rollback-timer.timer
      systemctl stop auto-rollback-timer.service
      exit 0
    }
    
    CURRENT_GEN=$(readlink -f /run/current-system | grep -o '[0-9]\+' | head -n1)
    
    # Display the message on all ttys and via wall
    for tty in /dev/tty*; do
      if [ -w "$tty" ]; then
        echo -e "\n\033[1;31mWARNING: System generation changed to $CURRENT_GEN.\033[0m" > $tty
        echo -e "\033[1;31mPress any key within 5 minutes to confirm this generation works.\033[0m" > $tty
        echo -e "\033[1;31mOtherwise, system will roll back automatically.\033[0m\n" > $tty
      fi
    done
    
    # Also send wall message for SSH users
    ${pkgs.utillinux}/bin/wall "WARNING: System generation changed to $CURRENT_GEN. Press any key within 5 minutes to confirm or system will roll back."
    
    # Set up trap to clean up on exit
    trap cleanup INT TERM
    
    # Set up named pipe for input
    PIPE_DIR="/run/auto-rollback"
    mkdir -p "$PIPE_DIR"
    PIPE="$PIPE_DIR/confirmation-pipe"
    
    # Remove pipe if it exists
    rm -f "$PIPE"
    
    # Create named pipe
    mkfifo "$PIPE"
    
    # For local terminals
    for tty in /dev/tty*; do
      if [ -w "$tty" ] && [ -r "$tty" ]; then
        # Launch background cat process that will exit on first keypress
        cat "$tty" > "$PIPE" &
      fi
    done
    
    # For SSH users (create a temporary socket that accepts connections)
    ${pkgs.socat}/bin/socat TCP-LISTEN:${toString cfg.sshConfirmPort},bind=127.0.0.1,fork PIPE:"$PIPE" &
    SOCAT_PID=$!
    
    # Add instructions to motd for SSH users
    MOTD_FILE="/etc/motd.rollback"
    echo -e "\n\033[1;31mWARNING: System generation confirmation needed.\033[0m" > $MOTD_FILE
    echo -e "\033[1;31mTo confirm the current generation works, run:\033[0m" >> $MOTD_FILE
    echo -e "\033[1;31mecho 'confirm' | nc localhost ${toString cfg.sshConfirmPort}\033[0m\n" >> $MOTD_FILE
    
    # Link the motd
    ln -sf "$MOTD_FILE" /etc/motd
    
    # Wait for input from pipe (any key)
    if read -t 300 -n 1 input < "$PIPE"; then
      # User confirmed, cancel rollback
      systemctl stop auto-rollback-timer.timer
      ${pkgs.utillinux}/bin/wall "System generation $CURRENT_GEN confirmed. Rollback canceled."
      echo "User confirmed generation $CURRENT_GEN, canceling rollback."
      
      # Clean up
      rm -f "$PIPE"
      rm -f "$MOTD_FILE"
      rm -f /etc/motd
      kill $SOCAT_PID 2>/dev/null || true
      exit 0
    else
      # Shouldn't get here normally, the timer should trigger first
      # But just in case, let's roll back
      "${rollbackScript}"
    fi
  '';
  
  # Script to perform the rollback
  rollbackScript = pkgs.writeScript "perform-rollback" ''
    #!/bin/sh
    
    # Get the previous generation
    CURRENT_GEN=$(readlink -f /run/current-system | grep -o '[0-9]\+' | head -n1)
    PREV_GEN=$((CURRENT_GEN - 1))
    
    # Announce the rollback
    ${pkgs.utillinux}/bin/wall "WARNING: No confirmation received. Rolling back from generation $CURRENT_GEN to generation $PREV_GEN in 10 seconds..."
    
    # Sleep to give the user a chance to see the message
    sleep 10
    
    # Perform the rollback
    ${pkgs.utillinux}/bin/wall "Performing rollback now..."
    /run/current-system/bin/switch-to-configuration test || true
    /nix/var/nix/profiles/system-$PREV_GEN-link/bin/switch-to-configuration switch
    
    # Reboot if configured
    if [ ${toString cfg.rebootAfterRollback} = 1 ]; then
      ${pkgs.utillinux}/bin/wall "Rollback complete. Rebooting in 5 seconds..."
      sleep 5
      reboot
    else
      ${pkgs.utillinux}/bin/wall "Rollback complete. Please reboot when convenient."
    fi
  '';

in {
  options.services.auto-rollback = {
    enable = mkEnableOption "automatic rollback if a new generation is not confirmed";
    
    sshConfirmPort = mkOption {
      type = types.port;
      default = 2323;
      description = "Port to listen on for SSH confirmation";
    };
    
    rebootAfterRollback = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to reboot after rolling back";
    };
  };

  config = mkIf cfg.enable {
    # Make sure the tools we need are installed
    environment.systemPackages = with pkgs; [
      netcat
      socat
      utillinux
    ];
    
    # Allow the confirmation port in the firewall (local only)
    networking.firewall.extraCommands = ''
      iptables -A INPUT -p tcp --dport ${toString cfg.sshConfirmPort} -s 127.0.0.1 -j ACCEPT
    '';
    
    # Service to check for generation changes after boot
    systemd.services.check-generation-change = {
      description = "Check if NixOS generation has changed";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network.target" ];
      after = [ "network.target" ];
      
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${checkGenScript}";
      };
    };
    
    # Service for prompting confirmation
    systemd.services.generation-confirmation = {
      description = "Prompt for confirmation of new NixOS generation";
      after = [ "network.target" ];
      
      serviceConfig = {
        Type = "simple";
        ExecStart = "${confirmationScript}";
      };
    };
    
    # Service for checking generation change after each nixos-rebuild
    systemd.services.post-rebuild-check = {
      description = "Check for generation change after nixos-rebuild";
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${checkGenScript}";
      };
      
      # This makes the confirmation service start when this service exits successfully
      # (which happens when a generation change is detected)
      unitConfig = {
        OnSuccess = "generation-confirmation.service";
      };
    };
    
    # Timer for auto-rollback
    systemd.timers.auto-rollback-timer = {
      description = "Timer for automatic rollback if no confirmation";
      
      timerConfig = {
        OnActiveSec = "5min";
        AccuracySec = "1s";
      };
      
      wantedBy = [];  # Not started automatically, only by the confirmation script
    };
    
    # Service executed by the timer to perform rollback
    systemd.services.auto-rollback-timer = {
      description = "Perform automatic rollback if no confirmation received";
      
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${rollbackScript}";
      };
    };
    
    # Add a path activation hook for nixos-rebuild
    system.activationScripts.check-generation-change = ''
      # Trigger the generation check service
      systemctl start post-rebuild-check.service || true
    '';
  };
}
