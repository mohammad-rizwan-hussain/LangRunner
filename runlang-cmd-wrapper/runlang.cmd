@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module RunLang -Force; runlang %*"
