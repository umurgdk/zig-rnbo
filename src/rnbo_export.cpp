#include <__config>
#define VECTOR_LEN 128

#include "RNBO.h"

// extern "C" RNBO::PatcherFactoryFunctionPtr GetPatcherFactoryFunction(RNBO::PlatformInterface* platformInterface);

extern "C" {
typedef struct {
	void *userinfo;
	void (*onBangEvent)(void *userinfo, void *object, uint32_t tag);
	void (*onNumberEvent)(void *userinfo, void *object, uint32_t tag, RNBO::number value);
	void (*onError)(void *userinfo, void *object);
} EventHandlerCallbacks;
}

class PassthroughEventHandler : RNBO::EventHandler {
public:
	PassthroughEventHandler(EventHandlerCallbacks callbacks, RNBO::CoreObject *object) : m_callbacks(callbacks), m_object(object) {
		m_event_interface = object->createParameterInterface(
			RNBO::ParameterEventInterface::Type::MultiProducer,
			this
		);
	}

	EventHandlerCallbacks m_callbacks;

private:
	RNBO::CoreObject      *m_object;
	RNBO::ParameterEventInterfaceUniquePtr m_event_interface;

	void eventsAvailable() override {
		drainEvents();
	}

	void handleMessageEvent(const RNBO::MessageEvent &event) override {
		try {
			switch (event.getType()) {
				case RNBO::MessageEvent::Type::Number:
					m_callbacks.onNumberEvent(m_callbacks.userinfo, m_object, event.getTag(), event.getNumValue());
					break;

				case RNBO::MessageEvent::Type::Bang:
					m_callbacks.onBangEvent(m_callbacks.userinfo, m_object, event.getTag());
					break;
				default:
				break;
			}
		} catch (...) {
			m_callbacks.onError(m_callbacks.userinfo, m_object);
		}
	}
};

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
typedef void * PresetListRef;
typedef void * PresetRef;
typedef void * EventHandlerRef;

CoreObjectRef _Nullable rnbo_objectNew() {
	// auto patcher_interface = GetPatcherFactoryFunction(RNBO::Platform::get())();
	RNBO::CoreObject *object = new RNBO::CoreObject();
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

void rnbo_objectSetPreset(CoreObjectRef obj, PresetRef preset) {
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


int rnbo_objectProcessInterleaved(CoreObjectRef obj, RNBO::SampleValue *input, size_t input_channels, RNBO::SampleValue * const output, size_t output_channels, size_t num_frames) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	RNBO::SampleValue const *input_ptr = static_cast<RNBO::SampleValue const *>(input);
	try {
		object->process<RNBO::SampleValue const *, RNBO::SampleValue * const>(input_ptr, input_channels, output, output_channels, num_frames);
		return 0;
	} catch (...) {
		return -1;
	}
}

int rnbo_objectGetParameterIndexForId(CoreObjectRef obj, const char *id) {
	try {
		RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
		int result = object->getParameterIndexForID(id);
		return result;
	} catch(...) {
		return -1;
	}
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

typedef void (*ExternalDataReleaseFn)(const char *id, char *address, void *userdata);

void rnbo_objectSetExternalData(CoreObjectRef obj, const char *id, char *data, size_t data_size, rnbo_BufferType type, ExternalDataReleaseFn release_cb, void *userdata) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);

	RNBO::ReleaseCallback wrapped_cb = nullptr;
	if (release_cb) {
		wrapped_cb = [release_cb, userdata](RNBO::ExternalDataId memId, char *addr) {
			release_cb(memId, addr, userdata);
		};
	}

	switch (type.tag) {
		case RNBO_BUFFER_TYPE_FLOAT32: {
			RNBO::Float32AudioBuffer buffer_type(type.channels, type.samplerate);
			object->setExternalData(id, data, data_size, buffer_type, wrapped_cb);
		} break;

		case RNBO_BUFFER_TYPE_FLOAT64: {
			RNBO::Float64AudioBuffer buffer_type(type.channels, type.samplerate);
			object->setExternalData(id, data, data_size, buffer_type, wrapped_cb);
		} break;

		case RNBO_BUFFER_TYPE_UNTYPED: {
			RNBO::UntypedDataBuffer untyped;
			object->setExternalData(id, data, data_size, untyped, wrapped_cb);
		} break;
	}
}

bool rnbo_objectSendMessage(CoreObjectRef obj, const char *tag) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	try {
		object->sendMessage(RNBO::TAG(tag), RNBO::TAG(""));
		return true;
	} catch (...) {
		return false;
	}
}

bool rnbo_objectSendMessageWithNumber(CoreObjectRef obj, const char *tag, RNBO::number value) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	try {
		object->sendMessage(RNBO::TAG(tag), value, RNBO::TAG(""));
		return true;
	} catch (...) {
		return false;
	}
}

const char *rnbo_objectResolveTag(CoreObjectRef obj, uint32_t tag) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	try {
		return object->resolveTag(tag);
	} catch (...) {
		return nullptr;
	}
}

///////////////////////////////////////////////////////////////////////////////////////////////////
/// 
/// RNBO::PresetList
///

PresetListRef rnbo_presetListFromMemory(const char *preset_data) {
	RNBO::PresetList *preset_list = new RNBO::PresetList(preset_data);
	return preset_list;
}

void rnbo_presetListDestroy(PresetListRef preset_list) {
	RNBO::PresetList *p = static_cast<RNBO::PresetList *>(preset_list);
	delete p;
}

PresetRef rnbo_presetListPresetAtIndex(PresetListRef preset_list, size_t index) {
	RNBO::PresetList *p = static_cast<RNBO::PresetList *>(preset_list);
	auto preset = p->presetAtIndex(index);
	return preset.release();
}

PresetRef rnbo_presetListPresetWithName(PresetListRef preset_list, const char *name) {
	RNBO::PresetList *p = static_cast<RNBO::PresetList *>(preset_list);
	auto preset = p->presetWithName(name);
	return preset.release();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
/// 
/// EventHandler
///

EventHandlerRef rnbo_newEventHandler(CoreObjectRef obj, EventHandlerCallbacks callbacks) {
	RNBO::CoreObject *object = static_cast<RNBO::CoreObject *>(obj);
	PassthroughEventHandler *event_handler = new PassthroughEventHandler(callbacks, object);
	return event_handler;
}

void rnbo_destroyEventHandler(EventHandlerRef event_handler_ptr) {
	PassthroughEventHandler *event_handler = static_cast<PassthroughEventHandler *>(event_handler_ptr);
	delete event_handler;
}

EventHandlerCallbacks rnbo_eventHandlerGetCallbacks(EventHandlerRef event_handler_ptr) {
	PassthroughEventHandler *event_handler = static_cast<PassthroughEventHandler *>(event_handler_ptr);
	return event_handler->m_callbacks;
}

}
