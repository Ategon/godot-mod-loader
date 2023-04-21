class_name _ModLoaderScriptExtension
extends Reference


# This Class provides methods for working with script extensions.
# Currently all of the included methods are internal and should only be used by the mod loader itself.

const LOG_NAME := "ModLoader:ScriptExtension"


# Couple the extension paths with the parent paths and the extension's mod id
# in a ScriptExtensionData resource
# We need to pass the UNPACKED_DIR constant because the global ModLoader is not available during _init().
static func handle_script_extensions(UNPACKED_DIR: String) -> void:
	var script_extension_data_array := []
	for extension_path in ModLoaderStore.script_extensions:

		if not File.new().file_exists(extension_path):
			ModLoaderLog.error("The child script path '%s' does not exist" % [extension_path], LOG_NAME)
			continue

		var child_script = ResourceLoader.load(extension_path)

		var mod_id: String = extension_path.trim_prefix(UNPACKED_DIR).get_slice("/", 0)

		var parent_script: Script = child_script.get_base_script()
		var parent_script_path: String = parent_script.resource_path

		if not ModLoaderStore.loaded_vanilla_parents_cache.keys().has(parent_script_path):
			ModLoaderStore.loaded_vanilla_parents_cache[parent_script_path] = parent_script

		script_extension_data_array.push_back(
			ScriptExtensionData.new(extension_path, parent_script_path, mod_id)
		)

	# Sort the extensions based on dependencies
	script_extension_data_array = _sort_extensions_from_load_order(script_extension_data_array)

	# Inheritance is more important so this called last
	script_extension_data_array.sort_custom(InheritanceSorting, "_check_inheritances")

	# This saved some bugs in the past.
	ModLoaderStore.loaded_vanilla_parents_cache.clear()

	# Load and install all extensions
	for extension in script_extension_data_array:
		var script: Script = apply_extension(extension.extension_path)
		_reload_vanilla_child_classes_for(script)


# Inner class so the sort function can be called by handle_script_extensions()
class InheritanceSorting:
	# Go up extension_a's inheritance tree to find if any parent shares the same vanilla path as extension_b
	static func _check_inheritances(extension_a: ScriptExtensionData, extension_b: ScriptExtensionData)->bool:
		var a_child_script: Script

		if ModLoaderStore.loaded_vanilla_parents_cache.keys().has(extension_a.parent_script_path):
			a_child_script = ResourceLoader.load(extension_a.parent_script_path)
		else:
			a_child_script = ResourceLoader.load(extension_a.parent_script_path)
			ModLoaderStore.loaded_vanilla_parents_cache[extension_a.parent_script_path] = a_child_script

		var a_parent_script: Script = a_child_script.get_base_script()

		if a_parent_script == null:
			return true

		var a_parent_script_path = a_parent_script.resource_path
		if a_parent_script_path == extension_b.parent_script_path:
			return false

		else:
			return _check_inheritances(ScriptExtensionData.new(extension_a.extension_path, a_parent_script_path, extension_a.mod_id), extension_b)


static func apply_extension(extension_path: String) -> Script:
	# Check path to file exists
	if not File.new().file_exists(extension_path):
		ModLoaderLog.error("The child script path '%s' does not exist" % [extension_path], LOG_NAME)
		return null

	var child_script: Script = ResourceLoader.load(extension_path)
	# Adding metadata that contains the extension script path
	# We cannot get that path in any other way
	# Passing the child_script as is would return the base script path
	# Passing the .duplicate() would return a '' path
	child_script.set_meta("extension_script_path", extension_path)

	# Force Godot to compile the script now.
	# We need to do this here to ensure that the inheritance chain is
	# properly set up, and multiple mods can chain-extend the same
	# class multiple times.
	# This is also needed to make Godot instantiate the extended class
	# when creating singletons.
	# The actual instance is thrown away.
	child_script.new()

	var parent_script: Script = child_script.get_base_script()
	var parent_script_path: String = parent_script.resource_path

	# We want to save scripts for resetting later
	# All the scripts are saved in order already
	if not ModLoaderStore.saved_scripts.has(parent_script_path):
		ModLoaderStore.saved_scripts[parent_script_path] = []
		# The first entry in the saved script array that has the path
		# used as a key will be the duplicate of the not modified script
		ModLoaderStore.saved_scripts[parent_script_path].append(parent_script.duplicate())
		ModLoaderStore.saved_scripts[parent_script_path].append(child_script)

	ModLoaderLog.info("Installing script extension: %s <- %s" % [parent_script_path, extension_path], LOG_NAME)
	child_script.take_over_path(parent_script_path)

	return child_script


# Sort an array of ScriptExtensionData following the load order
static func _sort_extensions_from_load_order(extensions: Array) -> Array:
	var extensions_sorted := []

	for _mod_data in ModLoaderStore.mod_load_order:
		for script in extensions:
			if script.mod_id == _mod_data.dir_name:
				extensions_sorted.push_front(script)

	return extensions_sorted


# Reload all children classes of the vanilla class we just extended
# Calling reload() the children of an extended class seems to allow them to be extended
# e.g if B is a child class of A, reloading B after apply an extender of A allows extenders of B to properly extend B, taking A's extender(s) into account
static func _reload_vanilla_child_classes_for(script: Script) -> void:
	if script == null:
		return
	var current_child_classes := []
	var actual_path: String = script.get_base_script().resource_path
	var classes: Array = ProjectSettings.get_setting("_global_script_classes")

	for _class in classes:
		if _class.path == actual_path:
			current_child_classes.push_back(_class)
			break

	for _class in current_child_classes:
		for child_class in classes:

			if child_class.base == _class.class:
				load(child_class.path).reload()


static func remove_all_extensions_from_all_scripts() -> void:
	var _to_remove_scripts: Dictionary = ModLoaderStore.saved_scripts.duplicate()
	for script in _to_remove_scripts:
		_remove_all_extensions_from_script(script)


# Used to remove a specific extension
static func _remove_specific_extension_from_script(extension_path: String) -> void:
	# Check path to file exists
	if not ModLoaderUtils.file_exists(extension_path):
		ModLoaderLog.error("The extension script path \"%s\" does not exist" % [extension_path], LOG_NAME)
		return

	var extension_script: Script = ResourceLoader.load(extension_path)
	var parent_script: Script = extension_script.get_base_script()
	var parent_script_path: String = parent_script.resource_path

	# Check if the script to reset has been extended
	if not ModLoaderStore.saved_scripts.has(parent_script_path):
		ModLoaderLog.error("The extension parent script path \"%s\" has not been extended" % [parent_script_path], LOG_NAME)
		return

	# Check if the script to reset has anything actually saved
	# If we ever encounter this it means something went very wrong in extending
	if not ModLoaderStore.saved_scripts[parent_script_path].size() > 0:
		ModLoaderLog.error("The extension script path \"%s\" does not have the base script saved, this should never happen, if you encounter this please create an issue in the github repository" % [parent_script_path], LOG_NAME)
		return

	var parent_script_extensions: Array = ModLoaderStore.saved_scripts[parent_script_path].duplicate()
	parent_script_extensions.remove(0)

	# Searching for the extension that we want to remove
	var found_script_extension: Script = null
	for script_extension in parent_script_extensions:
		if script_extension.get_meta("extension_script_path") == extension_path:
			found_script_extension = script_extension
			break

	if found_script_extension == null:
		ModLoaderLog.error("The extension script path \"%s\" has not been found in the saved extension of the base script" % [parent_script_path], LOG_NAME)
		return
	parent_script_extensions.erase(found_script_extension)

	# Preparing the script to have all other extensions reapllied
	_remove_all_extensions_from_script(parent_script_path)

	# Reapplying all the extensions without the removed one
	for script_extension in parent_script_extensions:
		apply_extension(script_extension.get_meta("extension_script_path"))


# Used to fully reset the provided script to a state prior of any extension
static func _remove_all_extensions_from_script(parent_script_path: String) -> void:
	# Check path to file exists
	if not ModLoaderUtils.file_exists(parent_script_path):
		ModLoaderLog.error("The parent script path \"%s\" does not exist" % [parent_script_path], LOG_NAME)
		return

	# Check if the script to reset has been extended
	if not ModLoaderStore.saved_scripts.has(parent_script_path):
		ModLoaderLog.error("The parent script path \"%s\" has not been extended" % [parent_script_path], LOG_NAME)
		return

	# Check if the script to reset has anything actually saved
	# If we ever encounter this it means something went very wrong in extending
	if not ModLoaderStore.saved_scripts[parent_script_path].size() > 0:
		ModLoaderLog.error("The parent script path \"%s\" does not have the base script saved, \nthis should never happen, if you encounter this please create an issue in the github repository" % [parent_script_path], LOG_NAME)
		return

	var parent_script: Script = ModLoaderStore.saved_scripts[parent_script_path][0]
	parent_script.take_over_path(parent_script_path)

	# Remove the script after it has been reset so we do not do it again
	ModLoaderStore.saved_scripts.erase(parent_script_path)