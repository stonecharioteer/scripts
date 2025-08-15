#!/bin/bash

set -euo pipefail

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Set system locale to en_US.UTF-8 and configure dependencies.

OPTIONS:
    -h, --help     Show this help message
    -v, --verify   Only verify current locale settings
    -c, --cleanup  Remove unused locales (keeps only en_US.UTF-8 and C/POSIX)

DESCRIPTION:
    This script configures the system to use en_US.UTF-8 locale by:
    - Generating the en_US.UTF-8 locale if not available
    - Setting all LC_* environment variables to en_US.UTF-8
    - Updating /etc/default/locale (requires sudo)
    - Configuring current shell session
    - Optionally removing unused locales to save disk space

EOF
}

verify_locale() {
    echo "Current locale settings:"
    locale
    echo
    echo "Available locales containing 'en_US.UTF-8':"
    locale -a | grep -i "en_us.utf" || echo "None found"
    echo
    echo "All available locales:"
    locale -a
}

cleanup_locales() {
    echo "Cleaning up unused locales..."
    echo "This will remove all locales except en_US.UTF-8 and C/POSIX"
    echo "WARNING: This action cannot be undone!"
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cleanup cancelled."
        return 0
    fi
    
    # Create new locale.gen with only essential locales
    echo "Backing up current locale configuration..."
    sudo cp /etc/locale.gen /etc/locale.gen.backup 2>/dev/null || true
    
    {
        echo "# Essential locales only"
        echo "en_US.UTF-8 UTF-8"
        echo "C.UTF-8 UTF-8"
    } | sudo tee /etc/locale.gen > /dev/null
    
    echo "Regenerating locales..."
    sudo locale-gen
    
    # Clean locale archive if it exists
    if [[ -f /usr/lib/locale/locale-archive ]]; then
        echo "Cleaning locale archive..."
        sudo localedef --delete-from-archive $(localedef --list-archive | grep -v -E '^(en_US\.utf8|C\.utf8|POSIX)$') 2>/dev/null || true
    fi
    
    echo "Locale cleanup complete!"
    echo "Backup saved as /etc/locale.gen.backup"
}

main() {
    local verify_only=false
    local cleanup_only=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--verify)
                verify_only=true
                shift
                ;;
            -c|--cleanup)
                cleanup_only=true
                shift
                ;;
            *)
                echo "Error: Unknown option '$1'" >&2
                echo "Use -h or --help for usage information." >&2
                exit 1
                ;;
        esac
    done
    
    if [[ "$verify_only" == "true" ]]; then
        verify_locale
        exit 0
    fi
    
    if [[ "$cleanup_only" == "true" ]]; then
        cleanup_locales
        exit 0
    fi
    
    echo "Setting up en_US.UTF-8 locale..."
    
    # Check if locale is already available
    if ! locale -a | grep -q "en_US.utf8\|en_US.UTF-8"; then
        echo "Generating en_US.UTF-8 locale (requires sudo)..."
        if command -v locale-gen >/dev/null 2>&1; then
            sudo locale-gen en_US.UTF-8
        elif [[ -f /usr/share/i18n/SUPPORTED ]]; then
            echo "en_US.UTF-8 UTF-8" | sudo tee -a /etc/locale.gen
            sudo locale-gen
        else
            echo "Warning: Could not generate locale automatically" >&2
            echo "You may need to install locales package or configure manually" >&2
        fi
    else
        echo "en_US.UTF-8 locale already available"
    fi
    
    # Update system-wide locale configuration
    echo "Updating system locale configuration..."
    {
        echo "LANG=en_US.UTF-8"
        echo "LANGUAGE=en_US:en"
        echo "LC_ALL=en_US.UTF-8"
        echo "LC_ADDRESS=en_US.UTF-8"
        echo "LC_COLLATE=en_US.UTF-8"
        echo "LC_CTYPE=en_US.UTF-8"
        echo "LC_IDENTIFICATION=en_US.UTF-8"
        echo "LC_MEASUREMENT=en_US.UTF-8"
        echo "LC_MESSAGES=en_US.UTF-8"
        echo "LC_MONETARY=en_US.UTF-8"
        echo "LC_NAME=en_US.UTF-8"
        echo "LC_NUMERIC=en_US.UTF-8"
        echo "LC_PAPER=en_US.UTF-8"
        echo "LC_TELEPHONE=en_US.UTF-8"
        echo "LC_TIME=en_US.UTF-8"
    } | sudo tee /etc/default/locale > /dev/null
    
    # Set for current session
    export LANG=en_US.UTF-8
    export LANGUAGE=en_US:en
    export LC_ALL=en_US.UTF-8
    
    # Update locale cache
    if command -v update-locale >/dev/null 2>&1; then
        sudo update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    fi
    
    echo "Locale configuration complete!"
    echo
    echo "Current session locale has been updated."
    echo "For permanent effect, please:"
    echo "1. Log out and log back in, OR"
    echo "2. Restart your terminal, OR" 
    echo "3. Run: source /etc/default/locale"
    echo
    echo "Available commands:"
    echo "- Verify settings: $(basename "$0") --verify"
    echo "- Clean unused locales: $(basename "$0") --cleanup"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi