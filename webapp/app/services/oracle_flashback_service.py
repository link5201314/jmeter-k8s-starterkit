from __future__ import annotations

import os
import json
from pathlib import Path
from typing import Optional
import paramiko
from io import StringIO


class SSHFlashbackError(Exception):
    """Base exception for SSH Flashback operations"""
    pass


class SSHConnectionError(SSHFlashbackError):
    """Raised when SSH connection fails"""
    pass


class SSHCommandError(SSHFlashbackError):
    """Raised when SSH command execution fails"""
    pass


def _read_ssh_config(config_data: dict) -> dict:
    """
    Parse SSH configuration from dict
    Expected keys: host, port, username, password, script_path
    """
    config = {
        "host": config_data.get("host", "").strip(),
        "port": int(config_data.get("port", 22)),
        "username": config_data.get("username", "").strip(),
        "password": config_data.get("password", "").strip(),
        "script_path": config_data.get("script_path", "/home/oracle/scripts").strip(),
    }
    
    if not config["host"]:
        raise ValueError("SSH host is required")
    if not config["username"]:
        raise ValueError("SSH username is required")
    if not config["password"]:
        raise ValueError("SSH password is required")
    
    return config


def execute_ssh_command(
    config: dict,
    script_name: str,
    pdb_name: Optional[str] = None,
    restore_point: Optional[str] = None,
) -> dict:
    """
    Execute a shell script on remote server via SSH
    
    Args:
        config: SSH configuration dict with host, port, username, password, script_path
        script_name: Name of the script to execute (e.g., 'create_rp.sh')
        pdb_name: PDB name (optional, for scripts that need it)
        restore_point: Restore point name (optional, for scripts that need it)
    
    Returns:
        dict with keys: success (bool), stdout (str), stderr (str), exit_code (int)
    """
    try:
        config = _read_ssh_config(config)
    except ValueError as e:
        return {
            "success": False,
            "stdout": "",
            "stderr": str(e),
            "exit_code": -1,
        }
    
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    
    try:
        # Connect to SSH server
        client.connect(
            hostname=config["host"],
            port=config["port"],
            username=config["username"],
            password=config["password"],
            timeout=30,
        )
        
        # Build command
        script_path = config["script_path"].rstrip("/")
        cmd = f"bash {script_path}/{script_name}"
        
        # Add parameters if provided
        if pdb_name:
            cmd += f' -p "{pdb_name}"'
        if restore_point:
            cmd += f' -r "{restore_point}"'
        
        # Execute command
        stdin, stdout, stderr = client.exec_command(cmd, timeout=300)
        
        exit_code = stdout.channel.recv_exit_status()
        stdout_text = stdout.read().decode("utf-8", errors="replace")
        stderr_text = stderr.read().decode("utf-8", errors="replace")
        
        return {
            "success": exit_code == 0,
            "stdout": stdout_text,
            "stderr": stderr_text,
            "exit_code": exit_code,
        }
    
    except paramiko.AuthenticationException as e:
        return {
            "success": False,
            "stdout": "",
            "stderr": f"SSH authentication failed: {str(e)}",
            "exit_code": -1,
        }
    except paramiko.SSHException as e:
        return {
            "success": False,
            "stdout": "",
            "stderr": f"SSH error: {str(e)}",
            "exit_code": -1,
        }
    except Exception as e:
        return {
            "success": False,
            "stdout": "",
            "stderr": f"Unexpected error: {str(e)}",
            "exit_code": -1,
        }
    finally:
        client.close()


def create_restore_point(config: dict, pdb_name: str, restore_point: str) -> dict:
    """Create a restore point for a PDB"""
    return execute_ssh_command(config, "create_rp.sh", pdb_name, restore_point)


def list_restore_points(config: dict, pdb_name: str) -> dict:
    """List available restore points for a PDB"""
    return execute_ssh_command(config, "current_rp.sh", pdb_name)


def delete_restore_point(config: dict, pdb_name: str, restore_point: str) -> dict:
    """Delete a restore point for a PDB"""
    return execute_ssh_command(config, "delete_rp.sh", pdb_name, restore_point)


def check_flashback_process(config: dict, pdb_name: str) -> dict:
    """Check if Flashback Restore is in progress for a PDB"""
    return execute_ssh_command(config, "fb_process.sh", pdb_name)


def restore_restore_point(config: dict, pdb_name: str, restore_point: str) -> dict:
    """Execute Flashback Restore for a PDB to a specific restore point"""
    return execute_ssh_command(config, "restore_rp.sh", pdb_name, restore_point)


def load_ssh_config_from_k8s_secret(secret_data: dict) -> dict:
    """
    Load and validate SSH configuration from K8s secret data
    
    Args:
        secret_data: dict with stringData from K8s secret
    
    Returns:
        Validated config dict
    """
    return _read_ssh_config(secret_data)
