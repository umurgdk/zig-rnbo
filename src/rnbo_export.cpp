#define VECTOR_LEN 128

#include "RNBO.h"

extern "C" RNBO::PatcherFactoryFunctionPtr GetPatcherFactoryFunction(RNBO::PlatformInterface* platformInterface);

extern "C" {

///////////////////////////////////////////////////////////////////////////////////////////////////
/// 
/// RNBO::DataType helper struct
///

typedef enum {
	RNBO_BUFFER_TYPE_FLOAT32 = 0,
	RNBO_BUFFER_TYPE_FLOAT64 = 1,
	RNBO_BUFFER_TYPE_UNTYPED = 2,
} rnbo_BufferTypeTag;

typedef struct {
	unsigned int tag;
	unsigned int channels;
	RNBO::number samplerate;
} rnbo_BufferType;

///////////////////////////////////////////////////////////////////////////////////////////////////
/// 
/// RNBO::CoreObject
///

typedef void * CoreObjectRef;

CoreObjectRef _Nullable rnbo_objectNew() {
	auto patcher_interface = GetPatcherFactoryFunction(RNBO::Platform::get())();
	RNBO::CoreObject *object = new RNBO::CoreObject(RNBO::UniquePtr<RNBO::PatcherInterface>(patcher_interface));
	return (CoreObjectRef)object;
}

void rnbo_objectInitialize(CoreObjectRef obj) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	object->initialize();
}

void rnbo_objectDestroy(CoreObjectRef obj) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	delete object;
}

void rnbo_objectPrepareToProcess(CoreObjectRef obj, size_t sample_rate, size_t chunk_size) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	object->prepareToProcess(sample_rate, chunk_size);
}

void rnbo_objectSetPreset(CoreObjectRef obj, void *preset) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	RNBO::PatcherState *patcher_state = static_cast<RNBO::PatcherState *>(preset);
	std::unique_ptr<RNBO::PatcherState> p(patcher_state);
	object->setPreset(std::move(p));
}

void rnbo_objectScheduleMidiEvent(CoreObjectRef obj, double time_ms, size_t port, const uint8_t *data, size_t data_len) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	object->scheduleEvent(RNBO::MidiEvent(time_ms, port, data, data_len));
}

void rnbo_objectProcess(CoreObjectRef obj, RNBO::SampleValue * const * inputs, size_t inputs_len, RNBO::SampleValue **outputs, size_t outputs_len, size_t num_frames) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	object->process(inputs, inputs_len, outputs, outputs_len, num_frames);
}


void rnbo_objectProcessInterleaved(CoreObjectRef obj, RNBO::SampleValue *input, size_t input_channels, RNBO::SampleValue * const output, size_t output_channels, size_t num_frames) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	RNBO::SampleValue const *input_ptr = static_cast<RNBO::SampleValue const *>(input);
	object->process<RNBO::SampleValue const *, RNBO::SampleValue * const>(input_ptr, input_channels, output, output_channels, num_frames);
}

int rnbo_objectGetParameterIndexForId(CoreObjectRef obj, const char *id) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	int result = object->getParameterIndexForID(id);
	return result;
}

RNBO::number rnbo_objectGetParameterValue(CoreObjectRef obj, int parameter_index) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	RNBO::number result = object->getParameterValue(parameter_index);
	return result;
}

void rnbo_objectSetParameterValue(CoreObjectRef obj, int parameter_index, RNBO::number value) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	object->setParameterValue(parameter_index, value);
}

void rnbo_objectSetParameterValueTime(CoreObjectRef obj, int parameter_index, RNBO::number value, double time) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	object->setParameterValue(parameter_index, value, time);
}

void rnbo_objectSetExternalData(CoreObjectRef obj, const char *id, char *data, size_t data_size, rnbo_BufferType type, void (*release_cb)(const char *id, char *address)) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);

	switch (type.tag) {
		case RNBO_BUFFER_TYPE_FLOAT32: {
			RNBO::Float32AudioBuffer buffer_type(type.channels, type.samplerate);
			object->setExternalData(id, data, data_size, buffer_type, release_cb);
		} break;

		case RNBO_BUFFER_TYPE_FLOAT64: {
			RNBO::Float64AudioBuffer buffer_type(type.channels, type.samplerate);
			object->setExternalData(id, data, data_size, buffer_type, release_cb);
		} break;

		case RNBO_BUFFER_TYPE_UNTYPED: {
			RNBO::UntypedDataBuffer untyped;
			object->setExternalData(id, data, data_size, untyped, release_cb);
		} break;
	}
}

///////////////////////////////////////////////////////////////////////////////////////////////////
/// 
/// RNBO::PresetList
///

void *rnbo_presetListFromMemory(const char *preset_data) {
	RNBO::PresetList *preset_list = new RNBO::PresetList(preset_data);
	return preset_list;
}

void rnbo_presetListDestroy(void *preset_list) {
	RNBO::PresetList *p = static_cast<RNBO::PresetList *>(preset_list);
	delete p;
}

void * rnbo_presetListPresetWithName(void *preset_list, const char *name) {
	RNBO::PresetList *p = static_cast<RNBO::PresetList *>(preset_list);
	auto preset = p->presetWithName(name);
	return preset.release();
}
}
