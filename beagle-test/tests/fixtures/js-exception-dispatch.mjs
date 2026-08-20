import {
  catch_dispatch,
  default_catch,
} from "../../../beagle-lib/lib/beagle/exception-dispatch.js";
import {
  ExceptionInfo,
  ex_data,
  ex_message,
} from "../../../beagle-lib/lib/beagle/exception-info.js";

export function recover_exception(thunk, events) {
  try {
    return thunk();
  } catch (caught) {
    switch (catch_dispatch(caught, [ExceptionInfo, TypeError, default_catch])) {
      case 0:
        events.push("exception-info");
        return { message: ex_message(caught), data: ex_data(caught) };
      case 1:
        events.push("type-error");
        return ex_message(caught);
      case 2:
        events.push("default");
        return caught;
    }
  } finally {
    events.push("finally");
  }
}
