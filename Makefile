.PHONY: fix
fix:
	@if [ $(issue) = 1 ]; then\
		sudo rm -f "/Applications/Parallels Desktop.app/Contents/Resources/repack_osx_install_app.sh";\
		sudo cp repack_osx_install_app.sh "/Applications/Parallels Desktop.app/Contents/Resources/repack_osx_install_app.sh";\
	fi