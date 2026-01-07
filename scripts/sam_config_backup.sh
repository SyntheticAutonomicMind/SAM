#!/usr/bin/env bash
# SAM Configuration Backup and Restore Script
# Usage: 
#   ./sam_config_backup.sh backup   - Create backup
#   ./sam_config_backup.sh restore  - Restore backup
#   ./sam_config_backup.sh test     - Rename config for testing (easily reversible)
#   ./sam_config_backup.sh untest   - Restore renamed config after testing

set -e

SAM_APP_SUPPORT="$HOME/Library/Application Support/SAM"
SAM_CACHE="$HOME/Library/Caches/sam"
BACKUP_DIR="$HOME/Desktop/SAM-Backup-$(date +%Y%m%d-%H%M%S)"
LATEST_BACKUP_LINK="$HOME/Desktop/SAM-Backup-Latest"

backup() {
    echo "🔹 Creating SAM configuration backup..."
    
    mkdir -p "$BACKUP_DIR"
    
    if [ -d "$SAM_APP_SUPPORT" ]; then
        echo "  📦 Backing up Application Support..."
        cp -R "$SAM_APP_SUPPORT" "$BACKUP_DIR/Application-Support-SAM"
        echo "     ✅ Backed up: $BACKUP_DIR/Application-Support-SAM"
    else
        echo "  ⚠️  No Application Support directory found"
    fi
    
    # Ask about cache backup (models are large)
    read -p "  📦 Backup models cache (~GB)? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ -d "$SAM_CACHE" ]; then
            echo "  📦 Backing up Caches (this may take a while)..."
            cp -R "$SAM_CACHE" "$BACKUP_DIR/Caches-sam"
            echo "     ✅ Backed up: $BACKUP_DIR/Caches-sam"
        else
            echo "  ⚠️  No Cache directory found"
        fi
    else
        echo "     ⏭️  Skipping cache backup"
    fi
    
    # Create symlink to latest backup
    rm -f "$LATEST_BACKUP_LINK"
    ln -s "$BACKUP_DIR" "$LATEST_BACKUP_LINK"
    
    echo ""
    echo "✅ Backup complete: $BACKUP_DIR"
    echo "   Symlink: $LATEST_BACKUP_LINK"
    echo ""
    echo "To test fresh install:"
    echo "  rm -rf \"$SAM_APP_SUPPORT\""
    echo ""
    echo "To restore:"
    echo "  $0 restore"
}

restore() {
    if [ ! -L "$LATEST_BACKUP_LINK" ]; then
        echo "❌ No backup found at $LATEST_BACKUP_LINK"
        echo "   Create a backup first: $0 backup"
        exit 1
    fi
    
    BACKUP_SOURCE=$(readlink "$LATEST_BACKUP_LINK")
    
    echo "🔹 Restoring SAM configuration from:"
    echo "   $BACKUP_SOURCE"
    echo ""
    
    read -p "  ⚠️  This will replace current config. Continue? [y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
    
    if [ -d "$BACKUP_SOURCE/Application-Support-SAM" ]; then
        echo "  📦 Restoring Application Support..."
        rm -rf "$SAM_APP_SUPPORT"
        cp -R "$BACKUP_SOURCE/Application-Support-SAM" "$SAM_APP_SUPPORT"
        echo "     ✅ Restored: $SAM_APP_SUPPORT"
    else
        echo "  ⚠️  No Application Support in backup"
    fi
    
    if [ -d "$BACKUP_SOURCE/Caches-sam" ]; then
        read -p "  📦 Restore models cache? [y/N]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "  📦 Restoring Caches..."
            rm -rf "$SAM_CACHE"
            cp -R "$BACKUP_SOURCE/Caches-sam" "$SAM_CACHE"
            echo "     ✅ Restored: $SAM_CACHE"
        else
            echo "     ⏭️  Skipping cache restore"
        fi
    fi
    
    echo ""
    echo "✅ Restore complete!"
}

test_mode() {
    echo "🔹 Entering test mode (renaming config, not deleting)..."
    
    if [ -d "$SAM_APP_SUPPORT" ]; then
        if [ -d "$SAM_APP_SUPPORT.test-backup" ]; then
            echo "❌ Test backup already exists: $SAM_APP_SUPPORT.test-backup"
            echo "   Run '$0 untest' first or delete manually"
            exit 1
        fi
        
        mv "$SAM_APP_SUPPORT" "$SAM_APP_SUPPORT.test-backup"
        echo "  ✅ Renamed: $SAM_APP_SUPPORT → $SAM_APP_SUPPORT.test-backup"
    else
        echo "  ℹ️  No config to rename"
    fi
    
    echo ""
    echo "✅ Test mode enabled!"
    echo "   SAM will show onboarding wizard on next launch"
    echo ""
    echo "To restore:"
    echo "  $0 untest"
}

untest_mode() {
    echo "🔹 Exiting test mode (restoring renamed config)..."
    
    if [ -d "$SAM_APP_SUPPORT.test-backup" ]; then
        if [ -d "$SAM_APP_SUPPORT" ]; then
            echo "  ⚠️  New config exists. Removing test config first..."
            rm -rf "$SAM_APP_SUPPORT"
        fi
        
        mv "$SAM_APP_SUPPORT.test-backup" "$SAM_APP_SUPPORT"
        echo "  ✅ Restored: $SAM_APP_SUPPORT.test-backup → $SAM_APP_SUPPORT"
    else
        echo "  ℹ️  No test backup found"
    fi
    
    echo ""
    echo "✅ Test mode disabled!"
}

show_usage() {
    cat << EOF
SAM Configuration Backup/Restore Tool

Usage:
  $0 <command>

Commands:
  backup   - Create full backup of SAM configuration
  restore  - Restore from latest backup
  test     - Temporarily rename config (safe testing)
  untest   - Restore renamed config
  help     - Show this help

Examples:
  # Safe testing (recommended)
  $0 test           # Rename config
  # ... test SAM onboarding ...
  $0 untest         # Restore config

  # Full backup/restore
  $0 backup         # Create backup
  $0 restore        # Restore from backup

Directories:
  Config:  $SAM_APP_SUPPORT
  Cache:   $SAM_CACHE
  Backups: ~/Desktop/SAM-Backup-*
EOF
}

case "${1:-}" in
    backup)
        backup
        ;;
    restore)
        restore
        ;;
    test)
        test_mode
        ;;
    untest)
        untest_mode
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        echo "❌ Unknown command: ${1:-<none>}"
        echo ""
        show_usage
        exit 1
        ;;
esac
