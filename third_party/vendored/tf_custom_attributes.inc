/**
 * [TF2] Custom Attributes
 * Framework to store / retrieve custom attributes on weapons.
 */

#if defined __tf_custom_attributes_included
	#endinput
#endif

#define __tf_custom_attributes_included

/**
 * Called after an entity has finished spawning.  Any manager plugins should add attribute
 * names / values to the provided KeyValues handle, and should return Plugin_Changed if they
 * have done so.
 */
forward Action TF2CustAttr_OnKeyValuesAdded(int entity, KeyValues kv);

/** 
 * Returns a read-only KeyValues handle containing the entity's attributes (if any), or
 * `INVALID_HANDLE` if the entity does not have any backing storage.
 * 
 * The handle returned by this function must be freed.
 */
native KeyValues TF2CustAttr_GetAttributeKeyValues(int entity);

/**
 * Copies the contents of a given KeyValues handle and attaches it to an entity, replacing any
 * custom attributes it previously had.
 * 
 * This is for advanced users only; this bypasses the OnKeyValuesAdded forward.
 */
native bool TF2CustAttr_UseKeyValues(int entity, KeyValues kv);

/**
 * Returns an entity's custom attribute's integer value, or `iDefaultValue` if the entity does
 * not have the attribute.
 */
native int TF2CustAttr_GetInt(int entity, const char[] attr, int iDefaultValue = 0);

/**
 * Returns an entity's custom attribute's float value, or `flDefaultValue` if the entity does
 * not have the attribute.
 */
native float TF2CustAttr_GetFloat(int entity, const char[] attr, float flDefaultValue = 0.0);

/**
 * Retrieves an entity's custom attribute's string value, or `defaultValue` if the entity does
 * not have the attribute.
 * 
 * The return value is the number of bytes written.
 */
native int TF2CustAttr_GetString(int entity, const char[] attr, char[] buffer, int maxlen,
		const char[] defaultValue = "");

public SharedPlugin __pl_tf_custom_attributes = {
	name = "tf2custattr",
	file = "tf_custom_attributes.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};
