# frozen_string_literal: true

require_relative "ai/version"
require "tracer"
require "irb"
require "openai"
require "tty-markdown"

module IRB
  module AI
    NULL_VALUE = "NULL RETURN VALUE"

    class << self
      def debug_mode?
        ENV["IRB_AI_DEBUG"] && !ENV["IRB_AI_DEBUG"].empty?
      end

      def ai_client
        @ai_client ||= OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])
      end

      def model=(model)
        @model
      end

      def model
        @model ||= "gpt-3.5-turbo"
      end

      def register_irb_commands
        ec = IRB::ExtendCommandBundle.instance_variable_get(:@EXTEND_COMMANDS)

        [
          [
            :explain,
            :Explain,
            nil,
            [:explain, IRB::ExtendCommandBundle::OVERRIDE_ALL]
          ]
        ].each do |ecconfig|
          ec.push(ecconfig)
          IRB::ExtendCommandBundle.def_extend_command(*ecconfig)
        end
      end

      def execute_expression(expression:, context_binding:, context_obj:)
        output = StringIO.new
        exception = nil
        return_value = IRB::AI::NULL_VALUE
        ObjectTracer
          .new(
            context_obj,
            output: output,
            colorize: false,
            header: "object-trace"
          )
          .start do
            ExceptionTracer
              .new(output: output, colorize: false, header: "exception-trace")
              .start do
                begin
                  return_value = eval(expression, context_binding)
                rescue Exception => e
                  exception = e
                end
              end
          end

        traces = output.string.split("\n")

        [return_value, exception, traces]
      end

      def send_messages(
        expression:,
        context_binding:,
        context_obj:,
        traces:,
        exception:,
        return_value:
      )
        messages = [
          {
            role: "system",
            content:
              "I will help you understand your Ruby application's behaviour."
          },
          {
            role: "user",
            content:
              generate_message(
                expression: expression,
                traces: traces,
                exception: exception,
                context_binding: context_binding,
                context_obj: context_obj,
                return_value: return_value
              )
          }
        ]

        puts "Getting response from OpenAI..."

        response =
          AI.ai_client.chat(parameters: { model: AI.model, messages: messages })

        if AI.debug_mode?
          puts "==================== Raw Response ===================="
          pp response
          puts "======================================================"
        end

        response
      end

      def generate_message(
        expression:,
        context_binding:,
        context_obj:,
        traces:,
        exception:,
        return_value:
      )
        information =
          information_section(
            expression: expression,
            traces: traces,
            exception: exception,
            context_binding: context_binding,
            context_obj: context_obj,
            return_value: return_value
          )

        request = request_section(expression: expression, exception: exception)
        msg = <<~MSG
          ### Information

          #{information}

          ### Request

          #{request}
        MSG

        if AI.debug_mode?
          puts "==================== Message ===================="
          puts msg
          puts "================================================="
        end

        msg
      end

      def information_section(
        expression:,
        context_binding:,
        context_obj:,
        traces:,
        exception:,
        return_value:
      )
        msg = <<~MSG
          - The expression `#{expression}` returned `#{return_value}` (ignore if its value equals to `#{IRB::AI::NULL_VALUE}`)
          - Here are the runtime traces when running the expression is evaluated (ignore if blank):

          #{traces.join("\n")}

          - The execution happened in the context of the object #{context_obj}
            - If a trace has `object-trace` header, that means the trace is about the execution of this object
            - If you see no `object-trace`, that means the object is not involved in the execution. if that's the case,
              you can ignore the context object and the code around the binding when generating the response
        MSG

        if exception
          msg += <<~MSG
            - The execution caused the following exception: #{exception} (ignore if blank)
              - Exception backtrace is: #{exception.backtrace}
              - If you see multiple `exception-trace`, that means multiple exceptions were raised during the execution
              - But only the last trace is directly associated with the exception you see above
              - Use other exception traces to understand the execution flow in general and don't assume they have direct link to the exception above
          MSG
        else
          msg += <<~MSG
            - The execution DID NOT cause an exception
              - Please ignore all `exception-trace`
          MSG
        end

        msg
      end

      def request_section(expression:, exception:)
        msg = <<~MSG
          Please respond in the following format, with markdown syntax, and use code highlight when appropriate:

          ```
          This is an analysis of the program's behaviour when running the expression `#{expression}`

          ### Code Summary (skip if no program source code is given)

          <summary of the program's intended behaviour from the given code (ignore the breakpoint)>

          ### Execution Summary

          <summary of the program's actual behaviour from the given traces>
          <unless the program failed due to an exception, DO NOT assume the program failed because of the `exception-trace`s>


          ### Execution Details

          <detailed step-by-step explanation of the program's actual behaviour based on the source code and given trace>
          <strictly follow the below format>

          <example>
          1. The program started at line 1
          2. The program called method `foo` at line 2
          3. The program called method `bar` at line 3
          4. The trace shows that the program raised an exception at line 4
          </example>
        MSG

        msg +=
          if exception
            <<~MSG
              ### Debugging Suggestion for #{exception}

              <potential causes of the error based on the program's execution details as explained in the previous section>
              <if you think the information is not sufficient, please explicit mention that and explain what information is missing>
            MSG
          else
            <<~MSG
            <DO NOT assume the program failed due to an exception>
            MSG
          end

        msg
      end

      def code_around_binding(b)
        original_colorize = IRB.conf[:USE_COLORIZE]
        IRB.conf[:USE_COLORIZE] = false
        file, line = b.source_location

        File.read(file).lines[(line - 20)..(line + 4)].join
      ensure
        IRB.conf[:USE_COLORIZE] = original_colorize
      end
    end
  end

  module ExtendCommand
    class Explain < IRB::ExtendCommand::Nop
      IRB_PATH = Gem.loaded_specs["irb"].full_gem_path

      category "AI"
      description "WIP"

      def self.transform_args(args)
        # Return a string literal as is for backward compatibility
        if args.empty? || string_literal?(args)
          args
        else # Otherwise, consider the input as a String for convenience
          args.strip.dump
        end
      end

      def execute(*args)
        input = args.first&.chomp

        expression, context_obj_expression = input.split(/\sas\s/, 2)

        unless expression
          puts "Please provide the expression to explain. Usage: `explain <expression> [as <context object>]]`"
          return
        end

        context_binding = irb_context.workspace.binding

        context_obj =
          if context_obj_expression
            eval(context_obj_expression, context_binding)
          else
            irb_context.workspace.main
          end

        return_value, exception, traces =
          IRB::AI.execute_expression(
            expression: expression,
            context_binding: context_binding,
            context_obj: context_obj
          )

        response =
          IRB::AI.send_messages(
            expression: expression,
            context_binding: context_binding,
            context_obj: context_obj,
            traces: traces,
            exception: exception,
            return_value: return_value
          )

        while error = response.dig("error", "message")
          if error.match?(/reduce the length/)
            if traces.length >= 1
              puts "The generated request is too long. Trying again with reduced runtimne traces..."
              traces = traces.last(traces.length / 2)
              response =
                IRB::AI.send_messages(
                  expression: expression,
                  context_binding: context_binding,
                  context_obj: context_obj,
                  traces: traces,
                  exception: exception,
                  return_value: return_value
                )
            else
              puts "The generated request is too long even without runtime traces. Please try again with a shorter expression."
              return
            end
          else
            puts "OpenAI returned an error: #{error["message"]}"
            return
          end
        end

        finish_reason = response.dig("choices", 0, "finish_reason")

        case finish_reason
        when "stop"
        when "length"
        else
          puts "OpenAI did not finish processing the request (reason: #{finish_reason}). Please try again."
          return
        end

        content = response.dig("choices", 0, "message", "content")
        puts content

        parsed = TTY::Markdown.parse(content)
        puts parsed
      end
    end
  end
end

IRB::AI.register_irb_commands
